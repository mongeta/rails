require 'set'
require 'active_support/core_ext/class/attribute_accessors'

module Mime
  class Mimes < Array
    def symbols
      @symbols ||= map {|m| m.to_sym }
    end

    %w(<< concat shift unshift push pop []= clear compact! collect!
    delete delete_at delete_if flatten! map! insert reject! reverse!
    replace slice! sort! uniq!).each do |method|
      module_eval <<-CODE, __FILE__, __LINE__ + 1
        def #{method}(*)
          @symbols = nil
          super
        end
      CODE
    end
  end

  SET              = Mimes.new
  EXTENSION_LOOKUP = {}
  LOOKUP           = Hash.new { |h, k| h[k] = Type.new(k) unless k.blank? }

  def self.[](type)
    return type if type.is_a?(Type)
    Type.lookup_by_extension(type.to_s)
  end

  def self.fetch(type)
    return type if type.is_a?(Type)
    EXTENSION_LOOKUP.fetch(type.to_s) { |k| yield k }
  end

  # Encapsulates the notion of a mime type. Can be used at render time, for example, with:
  #
  #   class PostsController < ActionController::Base
  #     def show
  #       @post = Post.find(params[:id])
  #
  #       respond_to do |format|
  #         format.html
  #         format.ics { render :text => post.to_ics, :mime_type => Mime::Type["text/calendar"]  }
  #         format.xml { render :xml => @people }
  #       end
  #     end
  #   end
  class Type
    @@html_types = Set.new [:html, :all]
    cattr_reader :html_types

    # These are the content types which browsers can generate without using ajax, flash, etc
    # i.e. following a link, getting an image or posting a form. CSRF protection
    # only needs to protect against these types.
    @@browser_generated_types = Set.new [:html, :url_encoded_form, :multipart_form, :text]
    cattr_reader :browser_generated_types
    attr_reader :symbol

    @register_callbacks = []

    # A simple helper class used in parsing the accept header
    class AcceptItem #:nodoc:
      attr_accessor :order, :name, :q

      def initialize(order, name, q=nil)
        @order = order
        @name = name.strip
        q ||= 0.0 if @name == Mime::ALL # default wildcard match to end of list
        @q = ((q || 1.0).to_f * 100).to_i
      end

      def to_s
        @name
      end

      def <=>(item)
        result = item.q <=> q
        result = order <=> item.order if result == 0
        result
      end

      def ==(item)
        name == (item.respond_to?(:name) ? item.name : item)
      end
    end

    class << self

      TRAILING_STAR_REGEXP = /(text|application)\/\*/
      PARAMETER_SEPARATOR_REGEXP = /;\s*\w+="?\w+"?/

      def register_callback(&block)
        @register_callbacks << block
      end

      def lookup(string)
        LOOKUP[string]
      end

      def lookup_by_extension(extension)
        EXTENSION_LOOKUP[extension.to_s]
      end

      # Registers an alias that's not used on mime type lookup, but can be referenced directly. Especially useful for
      # rendering different HTML versions depending on the user agent, like an iPhone.
      def register_alias(string, symbol, extension_synonyms = [])
        register(string, symbol, [], extension_synonyms, true)
      end

      def register(string, symbol, mime_type_synonyms = [], extension_synonyms = [], skip_lookup = false)
        Mime.const_set(symbol.upcase, Type.new(string, symbol, mime_type_synonyms))

        new_mime = Mime.const_get(symbol.upcase)
        SET << new_mime

        ([string] + mime_type_synonyms).each { |str| LOOKUP[str] = SET.last } unless skip_lookup
        ([symbol] + extension_synonyms).each { |ext| EXTENSION_LOOKUP[ext.to_s] = SET.last }

        @register_callbacks.each do |callback|
          callback.call(new_mime)
        end
      end

      def parse(accept_header)
        if accept_header !~ /,/
          accept_header = accept_header.split(PARAMETER_SEPARATOR_REGEXP).first
          if accept_header =~ TRAILING_STAR_REGEXP
            parse_data_with_trailing_star($1)
          else
            [Mime::Type.lookup(accept_header)]
          end
        else
          # keep track of creation order to keep the subsequent sort stable
          list, index = [], 0
          accept_header.split(/,/).each do |header|
            params, q = header.split(PARAMETER_SEPARATOR_REGEXP)
            if params.present?
              params.strip!

              if params =~ TRAILING_STAR_REGEXP
                parse_data_with_trailing_star($1).each do |m|
                  list << AcceptItem.new(index, m.to_s, q)
                  index += 1
                end
              else
                list << AcceptItem.new(index, params, q)
                index += 1
              end
            end
          end
          list.sort!

          # Take care of the broken text/xml entry by renaming or deleting it
          text_xml = list.index("text/xml")
          app_xml = list.index(Mime::XML.to_s)

          if text_xml && app_xml
            # set the q value to the max of the two
            list[app_xml].q = [list[text_xml].q, list[app_xml].q].max

            # make sure app_xml is ahead of text_xml in the list
            if app_xml > text_xml
              list[app_xml], list[text_xml] = list[text_xml], list[app_xml]
              app_xml, text_xml = text_xml, app_xml
            end

            # delete text_xml from the list
            list.delete_at(text_xml)

          elsif text_xml
            list[text_xml].name = Mime::XML.to_s
          end

          # Look for more specific XML-based types and sort them ahead of app/xml

          if app_xml
            idx = app_xml
            app_xml_type = list[app_xml]

            while(idx < list.length)
              type = list[idx]
              break if type.q < app_xml_type.q
              if type.name =~ /\+xml$/
                list[app_xml], list[idx] = list[idx], list[app_xml]
                app_xml = idx
              end
              idx += 1
            end
          end

          list.map! { |i| Mime::Type.lookup(i.name) }.uniq!
          list
        end
      end

      # For an input of <tt>'text'</tt>, returns <tt>[Mime::JSON, Mime::XML, Mime::ICS,
      # Mime::HTML, Mime::CSS, Mime::CSV, Mime::JS, Mime::YAML, Mime::TEXT]</tt>.
      #
      # For an input of <tt>'application'</tt>, returns <tt>[Mime::HTML, Mime::JS,
      # Mime::XML, Mime::YAML, Mime::ATOM, Mime::JSON, Mime::RSS, Mime::URL_ENCODED_FORM]</tt>.
      def parse_data_with_trailing_star(input)
        Mime::SET.select { |m| m =~ input }
      end

      # This method is opposite of register method.
      #
      # Usage:
      #
      #   Mime::Type.unregister(:mobile)
      def unregister(symbol)
        symbol = symbol.upcase
        mime = Mime.const_get(symbol)
        Mime.instance_eval { remove_const(symbol) }

        SET.delete_if { |v| v.eql?(mime) }
        LOOKUP.delete_if { |k,v| v.eql?(mime) }
        EXTENSION_LOOKUP.delete_if { |k,v| v.eql?(mime) }
      end
    end

    def initialize(string, symbol = nil, synonyms = [])
      @symbol, @synonyms = symbol, synonyms
      @string = string
    end

    def to_s
      @string
    end

    def to_str
      to_s
    end

    def to_sym
      @symbol
    end

    def ref
      to_sym || to_s
    end

    def ===(list)
      if list.is_a?(Array)
        (@synonyms + [ self ]).any? { |synonym| list.include?(synonym) }
      else
        super
      end
    end

    def ==(mime_type)
      return false if mime_type.blank?
      (@synonyms + [ self ]).any? do |synonym|
        synonym.to_s == mime_type.to_s || synonym.to_sym == mime_type.to_sym
      end
    end

    def =~(mime_type)
      return false if mime_type.blank?
      regexp = Regexp.new(Regexp.quote(mime_type.to_s))
      (@synonyms + [ self ]).any? do |synonym|
        synonym.to_s =~ regexp
      end
    end

    # Returns true if Action Pack should check requests using this Mime Type for possible request forgery. See
    # ActionController::RequestForgeryProtection.
    def verify_request?
      @@browser_generated_types.include?(to_sym)
    end

    def html?
      @@html_types.include?(to_sym) || @string =~ /html/
    end

    def respond_to?(method, include_private = false) #:nodoc:
      super || method.to_s =~ /(\w+)\?$/
    end

    private
      def method_missing(method, *args)
        if method.to_s =~ /(\w+)\?$/
          $1.downcase.to_sym == to_sym
        else
          super
        end
      end
  end
end

require 'action_dispatch/http/mime_types'
