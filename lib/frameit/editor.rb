module Frameit
  class Editor
    attr_accessor :screenshot # reference to the screenshot object to fetch the path, title, etc.
    attr_accessor :frame # the frame of the device
    attr_accessor :image # the current image used for editing
    attr_accessor :top_space_above_device

    def frame!(screenshot)
      self.screenshot = screenshot
      prepare_image

      if load_frame # e.g. Mac doesn't need a frame
        self.frame = MiniMagick::Image.open(load_frame)
      end

      if should_add_title?
        @image = complex_framing
      else
        # easy mode from 1.0 - no title or background
        width = offset['width']
        image.resize width # resize the image to fit the frame
        put_into_frame # put it in the frame
      end

      store_result # write to file system
    end

    def load_frame
      TemplateFinder.get_template(screenshot)
    end

    def prepare_image
      @image = MiniMagick::Image.open(screenshot.path)
    end


    private
      def store_result
        output_path = screenshot.path.gsub('.png', '_framed.png').gsub('.PNG', '_framed.png')
        image.format "png"
        image.write output_path
        Helper.log.info "Added frame: '#{File.expand_path(output_path)}'".green
      end

      # puts the screenshot into the frame
      def put_into_frame
        @image = frame.composite(image, "png") do |c|
          c.compose "Over"
          c.geometry offset['offset']
        end
      end

      def offset
        return @offset_information if @offset_information

        @offset_information = fetch_config['offset'] || Offsets.image_offset(screenshot)

        if @offset_information and (@offset_information['offset'] or @offset_information['offset'])
          return @offset_information
        end
        raise "Could not find offset_information for '#{screenshot}'"
      end

      #########################################################################################
      # Everything below is related to title, background, etc. and is not used in the easy mode
      #########################################################################################

      # this is used to correct the 1:1 offset information
      # the offset information is stored to work for the template images
      # since we resize the template images to have higher quality screenshots
      # we need to modify the offset information by a certain factor
      def modify_offset(multiplicator)
        # Format: "+133+50"
        hash = offset['offset']
        x = hash.split("+")[1].to_f * multiplicator
        y = hash.split("+")[2].to_f * multiplicator
        new_offset = "+#{x.round}+#{y.round}"
        @offset_information['offset'] = new_offset
      end

      # Do we add a background and title as well?
      def should_add_title?
        return (fetch_config['background'] and (fetch_config['title'] or fetch_config['keyword']))
      end

      # more complex mode: background, frame and title
      def complex_framing
        background = generate_background
        
        if self.frame # we have no frame on le mac
          resize_frame!
          @image = put_into_frame

          # Decrease the size of the framed screenshot to fit into the defined padding + background
          frame_width = background.width - fetch_config['padding'] * 2
          image.resize "#{frame_width}x"
        end

        @@image = put_device_into_background(background)

        if fetch_config['title']
          @image = add_title
        end

        image
      end

      # Returns a correctly sized background image
      def generate_background
        background = MiniMagick::Image.open(fetch_config['background'])

        if background.height != screenshot.size[1]
          background.resize "#{screenshot.size[0]}x#{screenshot.size[1]}!" # `!` says it should ignore the ratio
        end
        background
      end

      def put_device_into_background(background)
        left_space = (background.width / 2.0 - image.width / 2.0).round
        bottom_space = -(image.height / 10).round # to be just a bit below the image bottom
        bottom_space -= 40 if screenshot.is_portrait? # even more for portrait mode

        self.top_space_above_device = background.height - image.height - bottom_space

        @image = background.composite(image, "png") do |c|
          c.compose "Over"
          c.geometry "+#{left_space}+#{top_space_above_device}"
        end

        return image
      end

      # Resize the frame as it's too low quality by default
      def resize_frame!
        multiplicator = (screenshot.size[0].to_f / offset['width'].to_f) # by how much do we have to change this?
        new_frame_width = multiplicator * frame.width # the new width for the frame
        frame.resize "#{new_frame_width.round}x" # resize it to the calculated witdth
        modify_offset(multiplicator) # modify the offset to properly insert the screenshot into the frame later
      end

      # Add the title above the device
      def add_title
        title_images = build_title_images(image.width)
        keyword = title_images[:keyword]
        title = title_images[:title]

        sum_width = (keyword.width rescue 0) + title.width + keyword_padding
        top_space = (top_space_above_device / 2.0 - actual_font_size / 2.0).round # centered
        
        left_space = (image.width / 2.0 - sum_width / 2.0).round
        if keyword
          @image = image.composite(keyword, "png") do |c|
            c.compose "Over"
            c.geometry "+#{left_space}+#{top_space}"
          end
        end

        left_space += (keyword.width rescue 0) + keyword_padding
        @image = image.composite(title, "png") do |c|
          c.compose "Over"
          c.geometry "+#{left_space}+#{top_space}"
        end
        image
      end

      def actual_font_size
        (screenshot.size[0] / 20.0).round # depends on the width of the screenshot
      end

      def keyword_padding
        (actual_font_size / 2.0).round
      end

      # This will build 2 individual images with the title, which will then be added to the real image
      def build_title_images(max_width)
        words = [:keyword, :title].keep_if{ |a| fetch_text(a) } # optional keyword/title
        results = {}
        words.each do |key|
          # Create empty background
          empty_path = File.join(Helper.gem_path('frameit'), "lib/assets/empty.png")
          title_image = MiniMagick::Image.open(empty_path)
          image_height = actual_font_size * 2 # gets trimmed afterwards anyway, and on the iPad the `y` would get cut
          title_image.combine_options do |i|
            i.resize "#{max_width}x#{image_height}!" # `!` says it should ignore the ratio
          end

          # Add the actual title
          font = fetch_config[key.to_s]['font']
          title_image.combine_options do |i|
            i.font font if font
            i.gravity "Center"
            i.pointsize actual_font_size
            i.draw "text 0,0 '#{fetch_text(key)}'"
            i.fill fetch_config[key.to_s]['color']
          end
          title_image.trim # remove white space

          results[key] = title_image
        end
        results
      end

      # Loads the config (colors, background, texts, etc.)
      # Don't use this method to access the actual text and use `fetch_texts` instead
      def fetch_config
        return @config if @config

        config_path = File.join(File.expand_path("..", screenshot.path), "Framefile.json")
        config_path = File.join(File.expand_path("../..", screenshot.path), "Framefile.json") unless File.exists?config_path
        file = ConfigParser.new.load(config_path)
        return {} unless file # no config file at all
        @config = file.fetch_value(screenshot.path)
      end

      # Fetches the title + keyword for this particular screenshot
      def fetch_text(type)
        raise "Valid parameters :keyword, :title" unless [:keyword, :title].include?type

        # Try to get it from a keyword.strings or title.strings file
        strings_path = File.join(File.expand_path("..", screenshot.path), "#{type.to_s}.strings")
        if File.exists?strings_path
          parsed = StringsParser.parse(strings_path)
          result = parsed.find { |k, v| screenshot.path.include?k }
          return result.last if result
        end

        # No string files, fallback to Framefile config
        result = fetch_config[type.to_s]['text']      

        if !result and type == :title
          # title is mandatory
          raise "Could not get title for screenshot #{screenshot.path}. Please provide one in your Framefile.json".red
        end

        return result
      end

  end
end