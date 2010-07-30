class FlickrPhoto < Photo
  
  Photo.descendent_classes ||= []
  Photo.descendent_classes << self
    
  def validate
    # Check to make sure the user owns the flickr photo
    if self.user && self.api_response
      if self.api_response.is_a?(Net::Flickr::Photo)
        fp_flickr_user_id = self.api_response.owner
      else
        fp_flickr_user_id = self.api_response.owner.nsid
      end
      
      unless fp_flickr_user_id == self.user.flickr_identity.flickr_user_id
        errors.add(:user, "must own the photo on Flickr.")
      end
    end
  end
  
  def self.get_api_response(native_photo_id, options = {})
    flickr = Net::Flickr.authorize(FLICKR_API_KEY, FLICKR_SHARED_SECRET)
    if options[:user] && options[:user].flickr_identity
      flickr.auth.token = options[:user].flickr_identity.token
    end
    flickr.photos.get_info(native_photo_id)
  end
  
  def self.new_from_api_response(api_response, options = {})
    logger.debug "[DEBUG] api_response.class: #{api_response.class}"
    if api_response.is_a? Net::Flickr::Photo
      new_from_net_flickr(api_response, options)
    else
      new_from_flickraw(api_response, options)
    end
  end
  
  def self.new_from_net_flickr(fp, options = {})
    options.update(
      :native_photo_id => fp.id,
      :square_url => fp.source_url(:square),
      :thumb_url => fp.source_url(:thumb),
      :small_url => fp.source_url(:small),
      :medium_url => fp.source_url(:medium),
      :large_url => fp.source_url(:large),
      :original_url => fp.source_url(:original),
      :native_page_url => fp.page_url,
      :native_username => (fp.photo_xml.at('owner')[:username] rescue nil),
      :native_realname => (fp.photo_xml.at('owner')[:realname] rescue nil),
      :license => fp.photo_xml['license']
    )
    flickr_photo = FlickrPhoto.new(options)
    flickr_photo.api_response = fp
    flickr_photo
  end
  
  def self.new_from_flickraw(fp, options = {})
    FlickRaw.api_key = FLICKR_API_KEY
    FlickRaw.shared_secret = FLICKR_SHARED_SECRET
    urls = fp.urls.index_by(&:type)
    photopage_url = urls['photopage']._content rescue nil
    options.update(
      :native_photo_id => fp.id,
      :native_page_url => photopage_url,
      :native_username => fp.owner.username,
      :native_realname => fp.owner.realname,
      :license         => fp.license
    )
    
    # Set sizes
    unless sizes = options.delete(:sizes)
      if options[:user] && options[:user].flickr_identity
        sizes = flickr.photos.getSizes(:photo_id => fp.id, 
          :auth_token => options[:user].flickr_identity.token)
      else
        sizes = flickr.photos.getSizes(:photo_id => fp.id)
      end
    end
    sizes = sizes.index_by(&:label)
    options[:square_url]   ||= sizes['Square'].source rescue nil
    options[:thumb_url]    ||= sizes['Thumbnail'].source rescue nil
    options[:small_url]    ||= sizes['Small'].source rescue nil
    options[:medium_url]   ||= sizes['Medium'].source rescue nil
    options[:large_url]    ||= sizes['Large'].source rescue nil
    options[:original_url] ||= sizes['Original'].source rescue nil
    
    flickr_photo = new(options)
    flickr_photo.api_response = fp
    flickr_photo
  end
  
  #
  # Sync photo properties with Flickr original.  Right now, that just means
  # the URLs.
  #
  def sync
    fp = self.api_response || FlickrPhoto.get_api_response(self.native_photo_id, :user => self.user)
    old_urls = [self.square_url, self.thumb_url, self.small_url, 
                self.medium_url, self.large_url, self.original_url]
    new_urls = [fp.source_url(:square), fp.source_url(:thumb), 
                fp.source_url(:small), fp.source_url(:medium), 
                fp.source_url(:large), fp.source_url(:original)]
    if old_urls != new_urls
      self.square_url    = fp.source_url(:square)
      self.thumb_url     = fp.source_url(:thumb)
      self.small_url     = fp.source_url(:small)
      self.medium_url    = fp.source_url(:medium)
      self.large_url     = fp.source_url(:large)
      self.original_url  = fp.source_url(:original)
      self.save
    end
  end
  
  def to_observation  
    # Get the Flickr data
    fp = self.api_response || FlickrPhoto.get_api_response(self.native_photo_id, :user => self.user)
    unless fp.is_a?(Net::Flickr::Photo)
      fp = FlickrPhoto.get_api_response(self.native_photo_id, :user => self.user)
      self.api_response = fp
    end
    
    # Setup the observation
    observation = Observation.new
    observation.user = self.user if self.user
    observation.photos << self
    observation.description = fp.description
    observation.observed_on_string = fp.taken.to_s(:long)
    observation.munge_observed_on_with_chronic
    observation.time_zone = observation.user.time_zone if observation.user
    
    # Get the geo fields
    begin
      observation.place_guess = %w"locality region country".map do |tag|
        fp.geo.get_location.at(tag).inner_text rescue nil
      end.compact.join(', ').strip
      observation.latitude = fp.geo.latitude
      observation.longitude = fp.geo.longitude
    rescue Net::Flickr::APIError
    end
    
    # Try to get a taxon
    photo_taxa = to_taxa
    unless photo_taxa.blank?
      unless photo_taxa.detect{|t| t.rank_level.blank?}
        photo_taxa = photo_taxa.sort_by(&:rank_level)
      end
      observation.taxon = photo_taxa.detect(&:species_or_lower?)
      observation.taxon ||= photo_taxa.first
      
      if observation.taxon
        begin
          observation.species_guess = observation.taxon.common_name.name
        rescue
          observation.species_guess = observation.taxon.name
        end
      end
    end

    observation
  end
  
  # Try to extract known taxa from the tags of a flickr photo
  def to_taxa(options = {})
    self.api_response ||= FlickrPhoto.get_api_response(self.native_photo_id, :user => options[:user] || self.user)
    taxa = if api_response.tags.blank?
      []
    else
      # First try to find taxa matching taxonomic machine tags, then default 
      # to all tags
      tags = api_response.tags.values.map(&:raw)
      machine_tags = tags.select{|t| t =~ /taxonomy\:/}
      taxa = Taxon.tags_to_taxa(machine_tags) unless machine_tags.blank?
      taxa ||= Taxon.tags_to_taxa(tags)
      taxa
    end
    taxa.compact
  end
end
