#encoding: utf-8
class Place < ActiveRecord::Base
  has_ancestry
  belongs_to :user
  belongs_to :check_list, :dependent => :destroy
  belongs_to :source
  has_many :check_lists, :dependent => :destroy
  has_many :listed_taxa
  has_many :taxa, :through => :listed_taxa
  has_many :taxon_links, :dependent => :delete_all
  has_many :guides, :dependent => :nullify
  has_many :projects, :dependent => :nullify, :inverse_of => :place
  has_one :place_geometry, :dependent => :destroy
  has_one :place_geometry_without_geom, :class_name => 'PlaceGeometry', 
    :select => (PlaceGeometry.column_names - ['geom']).join(', ')
  
  before_save :calculate_bbox_area, :set_display_name
  after_save :check_default_check_list
  
  validates_presence_of :latitude, :longitude
  validates_length_of :name, :within => 2..500, 
    :message => "must be between 2 and 500 characters"
  validates_uniqueness_of :name, :scope => :ancestry, :unless => Proc.new {|p| p.ancestry.blank?}
  validate :validate_parent_is_not_self
  validate :validate_name_does_not_start_with_a_number
  
  has_subscribers :to => {
    :observations => {:notification => "new_observations", :include_owner => false}
  }

  preference :check_lists, :boolean, :default => true

  extend FriendlyId
  friendly_id :name, :use => :history, :reserved_words => PlacesController.action_methods.to_a
  def normalize_friendly_id(string)
    super_candidate = super(string)
    candidate = display_name.to_s.split(',').first.parameterize
    candidate = super_candidate if candidate.blank? || candidate == super_candidate
    if Place.where(:slug => candidate).exists? && !display_name.blank?
      candidate = display_name.parameterize
    end
    candidate
  end
  
  # Place to put a GeoPlanet response to avoid re-querying
  attr_accessor :geoplanet_response
  attr_accessor :html
  
  define_index do
    indexes name
    indexes display_name
    has place_type
    
    # HACK: TS doesn't seem to include attributes in the GROUP BY correctly
    # for Postgres when using custom SQL attr definitions.  It may or may not 
    # be fixed in more up-to-date versions, but the issue has been raised: 
    # http://groups.google.com/group/thinking-sphinx/browse_thread/thread/e8397477b201d1e4
    has :latitude, :as => :fake_latitude
    has :longitude, :as => :fake_longitude
    # END HACK
    
    has 'RADIANS(latitude)', :as => :latitude,  :type => :float
    has 'RADIANS(longitude)', :as => :longitude,  :type => :float
    set_property :delta => :delayed
  end
  
  FLICKR_PLACE_TYPES = ActiveSupport::OrderedHash.new
  FLICKR_PLACE_TYPES[:country]   = 12
  FLICKR_PLACE_TYPES[:region]    = 8 # Flickr regions are equiv to GeoPlanet "states", at least in the US
  FLICKR_PLACE_TYPES[:county]    = 9
  FLICKR_PLACE_TYPES[:locality]  = 7 # Flickr localities => GeoPlanet towns
  REJECTED_GEO_PLANET_PLACE_TYPE_CODES = [
    1,    # Building
    3,    # Nearby Building
    11,   # Postal Code
    22,   # Suburb
    23,   # Sports Team
    31,   # Time Zone
    32    # Nearby Intersection
  ]
  GEO_PLANET_PLACE_TYPES = {
    0 => 'Undefined',
    1 => 'Building',
    2 => 'Street Segment',
    3 => 'Nearby Building',
    4 => 'Street',
    5 => 'Intersection',
    6 => 'Street',
    7 => 'Town',
    8 => 'State',
    9 => 'County',
    10 => 'Local Administrative Area',
    11 => 'Postal Code',
    12 => 'Country',
    13 => 'Island',
    14 => 'Airport',
    15 => 'Drainage',
    16 => 'Land Feature',
    17 => 'Miscellaneous',
    18 => 'Nationality',
    19 => 'Supername',
    20 => 'Point of Interest',
    21 => 'Region',
    22 => 'Suburb',
    23 => 'Sports Team',
    24 => 'Colloquial',
    25 => 'Zone',
    26 => 'Historical State',
    27 => 'Historical County',
    29 => 'Continent',
    31 => 'Time Zone',
    32 => 'Nearby Intersection',
    33 => 'Estate',
    35 => 'Historical Town',
    36 => 'Aggregate'
  }
  GEO_PLANET_PLACE_TYPE_CODES = GEO_PLANET_PLACE_TYPES.invert
  INAT_PLACE_TYPES = {
    100 => 'Open Space',
    101 => 'Territory'
  }
  PLACE_TYPES = GEO_PLANET_PLACE_TYPES.merge(INAT_PLACE_TYPES).delete_if do |k,v|
    Place::REJECTED_GEO_PLANET_PLACE_TYPE_CODES.include?(k)
  end

  PLACE_TYPE_CODES = PLACE_TYPES.invert
  PLACE_TYPES.each do |code, type|
    PLACE_TYPE_CODES[type.downcase] = code
    const_set type.upcase.gsub(/\W/, '_'), code
    scope type.pluralize.underscore.to_sym, where("place_type = ?", code)
  end

  scope :dbsearch, lambda {|q| where("name LIKE ?", "%#{q}%")}
  
  scope :containing_lat_lng, lambda {|lat, lng|
    joins(:place_geometry).where("ST_Intersects(place_geometries.geom, ST_Point(?, ?))", lng, lat)
  }

  scope :bbox_containing_lat_lng, lambda {|lat, lng|
    where(
      "(swlng > 0 AND nelng < 0 AND swlat <= ? AND nelat >= ? AND (swlng <= ? OR nelng >= ?)) " +
      "OR (swlng * nelng >= 0 AND swlat <= ? AND nelat >= ? AND swlng <= ? AND nelng >= ?)", 
      lat, lat, lng, lng,
      lat, lat, lng, lng
    )
  }
  
  scope :containing_bbox, lambda {|swlat, swlng, nelat, nelng|
    where("swlat <= ? AND nelat >= ? AND swlng <= ? AND nelng >= ?", swlat, nelat, swlng, nelng)
  }
  
  # This can be very expensive.  Use sparingly, or scoped.
  scope :intersecting_taxon, lambda{|taxon|
    taxon_id = taxon.is_a?(Taxon) ? taxon.id : taxon.to_i
    joins("JOIN place_geometries ON place_geometries.place_id = places.id").
    joins("JOIN taxon_ranges ON taxon_ranges.taxon_id = #{taxon_id}").
    where("ST_Intersects(place_geometries.geom, taxon_ranges.geom)")
  }

  scope :listing_taxon, lambda {|taxon|
    taxon_id = if taxon.is_a?(Taxon)
      taxon
    elsif taxon.to_i == 0
      Taxon.single_taxon_for_name(taxon)
    else
      taxon
    end
    select("DISTINCT places.id, places.*").
    joins("LEFT OUTER JOIN listed_taxa ON listed_taxa.place_id = places.id").
    where("listed_taxa.taxon_id = ?", taxon_id)
  }

  scope :with_establishment_means, lambda {|establishment_means|
    scope = joins("LEFT OUTER JOIN listed_taxa ON listed_taxa.place_id = places.id").scoped
    case establishment_means
    when ListedTaxon::NATIVE
      scope.where("listed_taxa.establishment_means IN (?)", ListedTaxon::NATIVE_EQUIVALENTS)
    when ListedTaxon::INTRODUCED
      scope.where("listed_taxa.establishment_means IN (?)", ListedTaxon::INTRODUCED_EQUIVALENTS)
    else
      scope.where("listed_taxa.establishment_means = ?", establishment_means)
    end
  }
  
  scope :place_type, lambda {|place_type|
    place_type = PLACE_TYPE_CODES[place_type] if place_type.is_a?(String) && place_type.to_i == 0
    place_type = place_type.to_i
    where(:place_type => place_type)
  }
  
  scope :place_types, lambda {|place_types|
    place_types = place_types.map do |place_type|
      place_type = PLACE_TYPE_CODES[place_type] if place_type.is_a?(String) && place_type.to_i == 0
      place_type.to_i
    end
    where("place_type IN (?)", place_types)
  }

  scope :with_geom, joins(:place_geometry).where("place_geometries.id IS NOT NULL")
  
  def to_s
    "<Place id: #{id}, name: #{name}, woeid: #{woeid}, " + 
    "place_type_name: #{place_type_name}, lat: #{latitude}, " +
    "lng: #{longitude}, parent_id: #{parent_id}>"
  end
  
  def validate_parent_is_not_self
    if !id.blank? && id == ancestor_ids.last
      errors.add(:parent_id, "cannot be the same as the place itself")
    end
  end

  def validate_name_does_not_start_with_a_number
    if name.to_i > 0
      errors.add(:name, "cannot start with a number")
    end
  end
  
  def place_type_name
    PLACE_TYPES[place_type]
  end
  
  def place_type_name=(name)
    self.place_type = PLACE_TYPE_CODES[name]
  end
  
  # Wrap the attr call to set it if unset (or if :reload => true)
  def display_name(options = {})
    return read_attribute(:display_name) unless read_attribute(:display_name).blank? || options[:reload]
    
    ancestor_names = ancestors.reverse.select do |a|
      %w"town state country".include?(PLACE_TYPES[a.place_type].to_s.downcase)
    end.map do |a|
      a.code.blank? ? a.name : a.code.split('-').last
    end.compact
    
    new_name = if self.place_type_name == 'County' && ancestor_names.include?('US')
      "#{self.name} County"
    else
      self.name
    end
    new_display_name = [new_name, *ancestor_names].join(', ')
    unless new_record?
      Place.update_all(["display_name = ?", new_display_name], ["id = ?", id])
    end
    
    new_display_name
  end

  def set_display_name
    return true unless ancestry_changed?
    display_name(:reload => true)
    true
  end
  
  def wikipedia_name
    if %w"Town County".include? place_type_name
      display_name.gsub(', US', '')
    else
      name
    end
  end
  
  # Calculate and cache the bbox area for place area size queries
  def calculate_bbox_area
    if self.swlat && self.swlng && self.nelat && self.nelng && 
        (self.swlat_changed? || self.swlng_changed? || self.nelat_changed? || 
          self.nelng_changed?)
      height = self.nelat - self.swlat
      width = if self.straddles_date_line?
        (180 - self.swlng) + (180 - self.nelng*-1)
      else
        self.nelng - self.swlng
      end
      self.bbox_area = width * height
    end
    true
  end
  
  def straddles_date_line?
    self.swlng.to_f > 0 && self.nelng.to_f < 0
  end
  
  def contains_lat_lng?(lat, lng)
    swlat <= lat && nelat >= lat && swlng <= lng && nelng >= lng
  end
  
  def editable_by?(user)
    return false if user.blank?
    return true if user.is_curator?
    return true if self.user_id == user.id
    return false if %w(country state county).include?(place_type_name.to_s.downcase)
    false
  end
  
  # Import a place from Yahoo GeoPlanet using the WOEID (Where On Earth ID)
  def self.import_by_woeid(woeid, options = {})
    if existing = Place.find_by_woeid(woeid)
      return existing
    end
    
    begin
      ydn_place = GeoPlanet::Place.new(woeid.to_i)
    rescue GeoPlanet::NotFound => e
      Rails.logger.error "[ERROR] #{e.class}: #{e.message}"
      return nil
    end
    place = Place.new_from_geo_planet(ydn_place)
    begin
      unless place.save
        Rails.logger.error "[ERROR #{Time.now}] place [#{place.name}], ancestry: #{place.ancestry}, errors: #{place.errors.full_messages.to_sentence}"
        return
      end
    rescue PG::Error => e
      raise e unless e.message =~ /duplicate key/
      return
    end
    place.parent = options[:parent]
    
    unless (options[:ignore_ancestors] || ydn_place.ancestors.blank?)
      ancestors = []
      (ydn_place.ancestors || []).reverse_each do |ydn_ancestor|
        next if REJECTED_GEO_PLANET_PLACE_TYPE_CODES.include?(ydn_ancestor.placetype_code)
        ancestor = Place.import_by_woeid(ydn_ancestor.woeid, :ignore_ancestors => true, :parent => ancestors.last)
        ancestors << ancestor if ancestor
        place.parent = ancestor if place.persisted? && ancestor.persisted?
      end
    end
    
    place.save
    place
  end
  
  # Make a new Place from a GeoPlanet::Place
  def self.new_from_geo_planet(ydn_place)
    place = Place.new(
      :woeid => ydn_place.woeid,
      :latitude => ydn_place.latitude,
      :longitude => ydn_place.longitude,
      :place_type => ydn_place.placetype_code,
      :name => ydn_place.name
    )
    place.geoplanet_response = ydn_place
    if ydn_place.bounding_box
      place.swlat = ydn_place.bounding_box[0][0]
      place.swlng = ydn_place.bounding_box[0][1]
      place.nelat = ydn_place.bounding_box[1][0]
      place.nelng = ydn_place.bounding_box[1][1]
    end
    
    case ydn_place.placetype
    when 'State'
      place.code = ydn_place.admin1_code
    when 'Country'
      place.code = ydn_place.country_code
    end
    place
  end
  
  # Make a new Place from a flickraw place response
  def self.new_from_flickraw(flickr_place)
    Place.new(
      :woeid => flickr_place.woeid,
      :latitude => flickr_place.latitude,
      :longitude => flickr_place.longitude,
      :place_type => FLICKR_PLACE_TYPES[flickr_place.place_type.downcase.to_sym],
      :name => flickr_place.name,
      :parent => options[:parent]
    )
  end
  
  # Create a CheckList associated with this place
  def check_default_check_list
    if too_big_for_check_list? && !prefers_check_lists && check_list
      delay(:priority => USER_INTEGRITY_PRIORITY).remove_default_check_list
    end
    if place_type == PLACE_TYPE_CODES['Continent'] || too_big_for_check_list?
      self.prefers_check_lists = false
    end
    if prefers_check_lists && check_list.blank?
      self.create_check_list(:place => self)
      save(:validate => false)
      unless check_list.valid?
        Rails.logger.info "[INFO] Failed to create a default check list on " + 
          "creation of #{self}: " + 
          check_list.errors.full_messages.join(', ')
      end
    end
    true
  end

  def too_big_for_check_list?
    bbox_area.to_f > 100 && !user_id.blank?
  end

  def remove_default_check_list
    return unless check_list
    check_list.listed_taxa.delete_all
    check_list.destroy
  end
  
  # Update the associated place_geometry or create a new one
  def save_geom(geom, other_attrs = {})
    other_attrs.merge!(:geom => geom, :place => self)
    
    begin
      if place_geometry
        self.place_geometry.update_attributes(other_attrs)
      else
        pg = PlaceGeometry.create(other_attrs)
        self.place_geometry = pg
      end
      update_bbox_from_geom(geom) if self.place_geometry.valid?
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.error "[ERROR] \tCouldn't save #{self.place_geometry}: #{e.message[0..200]}"
    end
  end
  
  # Appends a geom instead of replacing it
  def append_geom(geom, other_attrs = {})
    new_geom = geom
    self.place_geometry.reload
    if self.place_geometry
      new_geom = MultiPolygon.from_geometries(
        self.place_geometry.geom.geometries + geom.geometries)
    end
    self.save_geom(new_geom, other_attrs)
  end
  
  # Update this place's bbox from a geometry.  Note this skips validations, 
  # but explicitly recalculates the bbox area
  def update_bbox_from_geom(geom)
    self.longitude = geom.envelope.center.x
    self.latitude = geom.envelope.center.y
    self.swlat = geom.envelope.lower_corner.y
    self.nelat = geom.envelope.upper_corner.y
    if geom.spans_dateline?
      self.longitude = geom.envelope.center.x + 180*(geom.envelope.center.x > 0 ? -1 : 1)
      self.swlng = geom.envelope.upper_corner.x
      self.nelng = geom.envelope.lower_corner.x
    else
      # self.longitude = geom.envelope.center.x
      self.swlng = geom.envelope.lower_corner.x
      self.nelng = geom.envelope.upper_corner.x
    end
    calculate_bbox_area
    save(:validate => false)
  end
  
  #
  # Import places from a shapefile.  Note that this is optimized for use with
  # a set of adapter methods in PlaceSources.  Note that this always assumes
  # shapefiles have a geographic projection using a NAD83 / WGS84 datum and
  # lat/lon coordinates.
  # Options:
  #   <tt>source</tt>: specify a type of handler for certain shapefiles.  Current options are 'census', 'esriworld', and 'cpad'
  #   <tt>skip_woeid</tt>: (boolean) Whether or not to require that the shape matches a unique WOEID.  This is based querying GeoPlanet for the name of the shape.
  #   <tt>test</tt>: (boolean) setting this to +true+ will do everything other than saving places and geometries.
  #   <tt>ancestor_place</tt>: (Place) scope searches for exissting records to descendents of this place. Matching will be based on name and place_type
  #
  # Examples:
  #   Census:
  #     Place.import_from_shapefile('/Users/kueda/Desktop/tl_2008_06_county/tl_2008_06_county.shp', :place_type => 'county', :source => 'census')
  #
  #   California Protected Areas Database:
  #     Place.import_from_shapefile('/Users/kueda/Desktop/CPAD_March09/Units_Fee_09_longlat.shp', :source => 'cpad', :skip_woeid => true)
  #
  def self.import_from_shapefile(shapefile_path, options = {}, &block)
    start_time = Time.now
    num_created = num_updated = 0
    src = options[:source]
    options.delete(:source) unless src.is_a?(Source)
    GeoRuby::Shp4r::ShpFile.open(shapefile_path).each do |shp|
      puts "[INFO] Working on shp..."
      new_place = case src
      when 'census'
        PlaceSources.new_place_from_census_shape(shp, options)
      when 'esriworld'
        PlaceSources.new_place_from_esri_world_shape(shp, options)
      when 'cpad'
        PlaceSources.new_place_from_cpad_units_fee(shp, options)
      else
        Place.new_from_shape(shp, options)
      end
      
      unless new_place
        puts "[INFO] \t\tShape couldn't be converted to a place.  Skipping..."
        next
      end
      
      new_place.source_filename = options[:source_filename] || File.basename(shapefile_path)
      new_place.source ||= src if src.is_a?(Source)
        
      puts "[INFO] \t\tMade new place: #{new_place}"
      unless new_place.woeid || options[:skip_woeid]
        puts "[INFO] \t\tCouldn't find a unique woeid. Skipping..."
        next
      end
      
      # Try to find an existing place
      existing = nil
      existing = Place.find_by_woeid(new_place.woeid) if new_place.woeid
      if new_place.source_filename && new_place.source_identifier
        existing ||= Place.first(:conditions => [
          "source_filename = ? AND source_identifier = ?", 
          new_place.source_filename, new_place.source_identifier])
      end
      if new_place.source_filename && new_place.source_name
        existing ||= Place.first(:conditions => [
          "source_filename = ? AND source_name = ?", 
          new_place.source_filename, new_place.source_name])
      end
      if options[:ancestor_place]
        existing ||= options[:ancestor_place].descendants.
          where("lower(name) = ? AND place_type = ?", new_place.name.downcase, new_place.place_type).first
      end
      
      if existing
        puts "[INFO] \t\tFound existing place: #{existing}"
        place = existing
        [:swlat, :swlng, :nelat, :nelng, :source_filename, :source_name, 
            :source_identifier].each do |attr_name|
          place.send("#{attr_name}=", new_place.send(attr_name)) if new_place.send(attr_name)
        end
        num_updated += 1
      else
        place = new_place.woeid ? Place.import_by_woeid(new_place.woeid) : new_place
        [:latitude, :longitude, :swlat, :swlng, :nelat, :nelng, :source_filename, :source_name, 
            :source_identifier, :place_type].each do |attr_name|
          place.send("#{attr_name}=", new_place.send(attr_name)) if new_place.send(attr_name)
        end
        num_created += 1
      end

      if options[:ancestor_place]
        place.parent ||= options[:ancestor_place]
      end
      
      place = if block_given?
        yield place, shp
      else
        place
      end
      begin
        if place && place.valid?
          place.save! unless options[:test]
          puts "[INFO] \t\tSaved place: #{place}, parent: #{place.parent.try(:name)}"
        else
          num_created -= 1
          puts "[ERROR] \tPlace invalid: #{place.errors.full_messages.join(', ')}" if place
          next
        end
      rescue => e
        puts "[ERROR] \tError: #{e}"
        next
      end
      
      next if options[:test]
      
      if existing && PlaceGeometry.exists?(
          ["place_id = ? AND updated_at >= ?", existing, start_time.utc])
        puts "[INFO] \t\tAppending to existing geom..."
        place.append_geom(shp.geometry, :source => options[:source])
      else
        puts "[INFO] \t\tAdding geom..."
        place.save_geom(shp.geometry, 
          :source => options[:source],
          :source_filename => place.source_filename,
          :source_name => place.source_name, 
          :source_identifier => place.source_identifier)
      end
      place.place_geometry_without_geom.dissolve_geometry
    end
    
    puts "\n[INFO] Finished importing places.  #{num_created} created, " + 
      "#{num_updated} updated (#{Time.now - start_time}s)"
  end
  
  #
  # Make a new Place from a shapefile shape
  #
  def self.new_from_shape(shape, options = {})
    name_column = options[:name_column] || 'name'
    skip_woeid = options[:skip_woeid]
    geoplanet_query = options[:geoplanet_query]
    geoplanet_options = options[:geoplanet_options] || {}
    name = options[:name] || 
      shape.data[name_column] || 
      shape.data[name_column.upcase] || 
      shape.data[name_column.capitalize] || 
      shape.data[name_column.downcase]
    place = Place.new(options.select{|k,v| Place.instance_methods.include?("#{k}=".to_sym)}.merge(
      :name => name,
      :latitude => shape.geometry.envelope.center.y,
      :longitude => shape.geometry.envelope.center.x,
      :swlat => shape.geometry.envelope.lower_corner.y,
      :swlng => shape.geometry.envelope.lower_corner.x,
      :nelat => shape.geometry.envelope.upper_corner.y,
      :nelng => shape.geometry.envelope.upper_corner.x
    ))
    
    unless skip_woeid
      puts "[INFO] \t\tTrying to find a unique WOEID from '#{geoplanet_query || place.name}'..."
      geoplanet_options[:count] = 2
      ydn_places = GeoPlanet::Place.search(geoplanet_query || place.name, geoplanet_options)
      if ydn_places && ydn_places.size == 1
        puts "[INFO] \t\tFound unique GeoPlanet place: " + 
          [ydn_places.first.name, ydn_places.first.woeid,
           ydn_places.first.placetype, ydn_places.first.admin2,
           ydn_places.first.admin1, ydn_places.first.country].join(', ')
        place.woeid = ydn_places.first.woeid
        place.geoplanet_response = ydn_places.first
      end
    end
    place
  end
  
  def merge(mergee, options = {})
    # Keep chosen attributes from the mergee
    if keepers = options[:keep]
      keepers =  [options[:keep]] unless keepers.is_a?(Array)
      keepers.each do |attr_name|
        self.send("#{attr_name}=", mergee.send(attr_name))
      end
    end
    
    # Hack!  We want to make sure the updates don't invalidate the place 
    # BEFORE we moving stuff around.  This hackery gets us around the unique 
    # name within a parent validation
    temp_name = self.name
    self.name += '_'
    unless self.valid?
      self.name = temp_name
      return self
    end
    self.name = temp_name
    
    # Move the mergee's listed_taxa to the target's default check list
    additional_taxon_ids = mergee.taxon_ids - self.taxon_ids
    ListedTaxon.update_all(
      ["place_id = ?, list_id = ?", self, self.check_list_id],
      ["place_id = ? AND taxon_id in (?)", mergee, additional_taxon_ids]
    )
    
    # Merge the geometries
    if self.place_geometry && mergee.place_geometry
      append_geom(mergee.place_geometry.geom)
    elsif mergee.place_geometry
      save_geom(mergee.place_geometry.geom)
    end
    
    # ensure any loaded associates that had their foreign keys updated in the db aren't hanging around
    mergee.reload

    mergee.destroy
    self.save
    self
  end
  
  def bounding_box
    box = [swlat, swlng, nelat, nelng].compact
    box.blank? ? nil : box
  end
  
  def contains_lat_lng?(lat, lng)
    PlaceGeometry.exists?([
      "place_id = ? AND " + 
      "ST_Intersects(place_geometries.geom, ST_Point(?, ?))",
      id, lng, lat
    ])
  end
  
  def bbox_contains_lat_lng?(lat, lng)
    return false if lat.blank? || lng.blank?
    return nil unless swlng && swlat && nelat && nelng
    if straddles_date_line?
      lat > swlat && lat < nelat && (lng > swlng || lng < nelng)
    else
      lat > swlat && lat < nelat && lng > swlng && lng < nelng
    end
  end

  def bbox_contains_lat_lng_acc?(lat, lng, acc)
    f = RGeo::Geographic.simple_mercator_factory
    bbox = f.polygon(
      f.linear_ring([
        f.point(swlng, swlat),
        f.point(swlng, nelat),
        f.point(nelng, nelat),
        f.point(nelng, swlat),
        f.point(swlng, swlat)
      ])
    )
    pt = f.point(lng,lat)

    # buffer the point to make a circle if accuracy set. Note that the method
    # takes accuracy in meters, not sure if it makes a conversion to degrees
    # with latitude in mind.
    pt = pt.buffer(acc) if acc.to_f > 0

    bbox.contains?(pt)
  end

  def kml_url
    FakeView.place_geometry_kml_url(:place => self)
  end
  
  def self.guide_cache_key(id)
    "place_guide_#{id}"
  end
  
  def as_json(options = {})
    options[:methods] ||= []
    options[:methods] << :place_type_name
    options[:except] ||= []
    options[:except] += [:source_filename, :delta, :bbox_area]
    super(options)
  end

  def self_and_ancestors
    [ancestors, self].flatten
  end

  def self_and_ancestor_ids
    [ancestor_ids, id].flatten
  end
end
