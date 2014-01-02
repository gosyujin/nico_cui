# -*-coding: utf-8 -*-
require 'nico_cui/version'
require 'thor'
require 'mechanize'
require 'nokogiri'
require 'pit'
require 'net/http'
require 'zlib'
require 'uri'
require 'logger'
require 'fileutils'
require 'pp'

# override Mechanize
class Mechanize
  def post_data(uri, data, query = {}, headers = {})
    if query.is_a?(String)
      return request_with_entity(:post, uri, query, headers)
    end
    node = {}
    # Create a fake form
    class << node
      def search(*args)
        []
      end
    end
    node['method'] = 'POST'
    # node['enctype'] = 'application/x-www-form-urlencoded'
    node['enctype'] = 'text/xml'

    form = Form.new(node)

    query.each do |k, v|
      if v.is_a?(IO)
        form.enctype = 'multipart/form-data'
        ul = Form::FileUpload.new(
          { 'name' => k.to_s }, ::File.basename(v.path))
        ul.file_data = v.read
        form.file_uploads << ul
      else
        form.fields << Form::Field.new({ 'name' => k.to_s }, v)
      end
    end

    cur_page = form.page || current_page || Page.new
    request_data = data
    log.debug("query: #{ request_data.inspect }") if log
    headers = {
      'Content-Type'    => form.enctype,
      'Content-Length'  => request_data.size.to_s,
    }.merge headers
    # fetch the page
    page = @agent.fetch uri, :post, headers, [request_data], cur_page
    add_to_history(page)
    page
  end
end

# NicoCui
module NicoCui
  # Thor commands
  class CLI < Thor
    class_option :help, aliases: '-h', type: :boolean,
                        desc: 'help'

    desc 'download [-a] video_number',
         'default'
    method_option :all, aliases: '-a', type: :boolean,
                        desc: "download mypage's all official videos"
    method_option :mylist, aliases: '-m', type: :boolean,
                           desc: "download mypage's official videos interactive"
    method_option :interactive, aliases: '-i', type: :boolean,
                                desc: "download mypage's official videos interactive"
    def download(*urls)
      if options[:all]
        Nico.new.get_video(:all)
      elsif options[:interactive]
      elsif options[:mylist]
        Nico.new.get_video(:mylist, urls)
      else
        Nico.new.get_video(:video, urls)
      end
    end
  end

  # Download logic
  class Nico
    LOGIN_URL        = 'https://secure.nicovideo.jp/secure/login_form'
    VIDEOINFO_URL    = 'http://ext.nicovideo.jp/api/getthumbinfo'
    COMMENT_URL      = 'http://flapi.nicovideo.jp/api/getflv'
    THREAD_ID_URL    = 'http://flapi.nicovideo.jp/api/getthreadkey'

    CONFIG           = YAML.load_file('_config.yml')
    CORE             = Pit.get(CONFIG['pit_id'])
    DL_PATH          = CONFIG['path']

    DL_URL           = 'http://www.nicovideo.jp/watch/'
    MY_LIST_URL      = 'http://www.nicovideo.jp/mylist/'
    MY_PAGE_TOP      = '/my/top'
    PAST_NICO_REPORT = 'next-page-link'
    GZIP_MAGICNUM    = ['1f8b']
    LOGIN_FAILED     = 'Log into Niconico'

    # not download smXXXXXXX
    IGNORE_NUMBER    = 'sm'
    IGNORE_TITLE     = "\r\n\t\t\t\t\t\t\t\t"

    # initalize and login
    def initialize
      @l = Logger.new(STDOUT)
      @l.datetime_format = '%Y-%m-%dT%H:%M:%S '
      @l.level = Logger::INFO

      @agent = ''
      @exist_files = []
      @dl_cores    = []

      @l.info { "download path: #{DL_PATH}" }
      FileUtils.mkdir_p(DL_PATH)
      Dir.glob("#{DL_PATH}/*").each do |file|
        @exist_files << File.basename(file, '.*')
      end
      @exist_files.uniq!

      @l.info('open login page')
      title = login
      if title == LOGIN_FAILED
        error_exit('login failed?(check mail and password)')
      end
    end

    # return: login page's title
    def login
      @agent = Mechanize.new
      login_page = @agent.get(LOGIN_URL)
      login_form = login_page.forms.first
      login_form['mail_tel'] = CORE['id']
      login_form['password'] = CORE['password']
      page = @agent.submit(login_form)
      page.title
    end

    def get_video(type, urls = nil)
      case type
      when :all
        @l.info('open my page')
        my_top_link = @agent.page.link_with(href: /#{MY_PAGE_TOP}/)
        error_exit("not found my page link: #{MY_PAGE_TOP}") if my_top_link.nil?

        @l.info { "search link '#{DL_URL}' in #{MY_PAGE_TOP}" }
        my_list = my_top_link.click

        @l.info("get video title and link from #{MY_PAGE_TOP}")
        @dl_cores = find_mypage(my_list)
      when :mylist
        @l.info { "open mylist: #{urls}" }
        rss = @agent.get("#{MY_LIST_URL}/#{urls[0]}?rss=2.0")
        doc = Nokogiri::XML(rss.body)
        urls = []
        doc.xpath('/rss/channel/item').each do |item|
          urls << File.basename(item.xpath('./link').text)
        end
        @dl_cores = get_videotitle(urls)
      when :video
        @l.info { "open url: #{urls}" }
        @dl_cores = get_videotitle(urls)
      end
      print "\n"

      @l.info('get description, tags')
      @l.info('================================')
      @l.debug { "@dl_cores: \n#{@dl_cores}" }
      @dl_cores.each do |dl|
        sleep(10)

        dl = get_videoinfo(dl)
        download(dl)
        @l.info('================================')
      end
    end

    def find_mypage(pages, dl_cores = nil)
      dl_cores = [] if dl_cores.nil?
      pages.links.each do |link|
        url = link.node.values[0]
        if url.match(/#{DL_URL}/)
          dl = {}
          dl['title']  = link.node.children.text
          dl['url']    = url
          dl['number'] = $'
          next if dl['title']        == IGNORE_TITLE
#          next if dl['number'].include? IGNORE_NUMBER
          dl_cores << dl
          print "\r#{dl_cores.size} videos: " \
                "#{dl['title'].bytesize}byte #{dl['title']}"
        elsif url.match(/#{PAST_NICO_REPORT}/) then
          past_url = link.node.values[1]
          find_mypage(@agent.get(past_url), dl_cores)
        end
      end
      dl_cores
    end

    # get a video's information
    # url: nico video url xxxxxxxxxx
    # return: { "title" => video's title
    #           "url"   => http://www.nicovideo.jp/watch/xxxxxxxxxx
    #           "number"=> xxxxxxxxxx }
    def get_videotitle(urls)
      dl_cores = []
      urls.each do |url|
        video_page = @agent.get("#{VIDEOINFO_URL}/#{url}")
        dl = {}
        dl['title']  = video_page.xml.children.children.search('title').text
        dl['url']    = "#{DL_URL}#{url}"
        dl['number'] = url
        dl_cores << dl
        print "\r#{dl_cores.size} videos: " \
              "#{dl['title'].bytesize}byte #{dl['title']}"
      end
      dl_cores
    end

    # get a video's description and tags
    def get_videoinfo(dl)
      res = @agent.get("#{VIDEOINFO_URL}/#{dl['number']}")
      res.xml.children.children.children.each do |child|
        case child.name
        when 'description'
          dl['description'] = child.content
        when 'tags'
          tags = []
          child.children.each do |c|
            case c.name
            when 'tag'
              tags << c.content
            end
          end
          dl['tags'] = tags
        end
      end
      dl
    end

    def download(dl)
      dl['title'] = dl['title'].gsub(/\//, '-')

      begin
        # check file bytesize
        FileUtils.touch("#{DL_PATH}/#{dl['title']}.html")
      rescue Errno::ENAMETOOLONG => ex
        @l.warn { "\n#{ex}" }
        dl['title'] = dl['title'][0, 50]
        @l.warn { "and TRUNCATE: #{dl["title"]}" }
        retry
      end

      @l.info { "download target: #{dl["title"]}" }

      comment_url = "#{COMMENT_URL}/#{dl["number"]}"
      params = get_params(comment_url)
      @l.debug { "comment_url : #{comment_url}" }

      message_server = params['ms'].nil? ? nil : URI.decode(params['ms'])
      video_server   = params['url'].nil? ? nil : URI.decode(params['url'])
      thread_id      = params['thread_id']
      user_id        = params['user_id']
      minutes        = (params['l'].to_i / 60) + 1

      thread_id_url = "#{THREAD_ID_URL}?thread=#{thread_id}"
      params.merge!(get_params(thread_id_url))
      @l.debug { "thread_id_url : #{thread_id_url}" }

      # skip error check when NOT official video(smxxxxxxx)
      unless dl['number'].include? IGNORE_NUMBER
        return if param_nil?(params, 'threadkey', 'Pay video?')
      end
      thread_key = params['threadkey']
      force_184  = params['force_184']

      @l.info('title, tags, description write')
      write(dl, "#{dl["title"]}.html")

      xml = <<-EOH
        <packet>
          <thread thread="#{thread_id}" user_id="#{user_id}"
            threadkey="#{thread_key}" force_184="#{force_184}"
            scores="1" version="20090904" res_from="-1000"
            with_global="1">
          </thread>
          <thread_leaves thread="#{thread_id}" user_id="#{user_id}"
            threadkey="#{thread_key}" force_184="#{force_184}"
            scores="1">
              0-#{minutes}:100,1000
          </thread_leaves>
        </packet>
      EOH
      @l.debug { "xml: \n#{xml}" }

      @l.info('comment get')
      return if param_nil?(params, 'ms', 'Pay video? or deleted?')
      begin
        @agent.content_encoding_hooks << lambda do |httpagent, uri, response, body_io|
          response['content-encoding'] = nil
        end
        res = @agent.post_data(message_server, xml)
      rescue Net::HTTP::Persistent::Error => ex
        @l.warn("\n#{ex}")
        @l.warn('retry')
        sleep(10)
        retry
      end

      begin
        # res.body: \x1F\x8B\.... => gzip
        if StringIO.open(res.body).read(2).unpack('H*') == GZIP_MAGICNUM
          @l.debug('comment format: gzip')
          content = StringIO.open(res.body, 'rb') do |r|
            Zlib::GzipReader.wrap(r).read
          end
        else
          @l.debug('comment format: xml')
          content = res.body
        end
        write(content, "#{dl["title"]}.xml")
      rescue Zlib::GzipFile::Error => ex
        @l.error("\n#{ex}")
        @l.debug("res.body: \n#{res.body}")
        return
      end

      @l.info('download start')
      return if param_nil?(params, 'url', 'Pay video?')
      if @exist_files.include?(dl['title'])
        @l.info('SKIP: video already exist')
        return
      end

      begin
        @agent.get(dl['url'])
        @agent.download(video_server, "#{DL_PATH}/#{dl["title"]}.mp4")
        @l.info('success')
      rescue Mechanize::ResponseCodeError => ex
        if ex.response_code == '403'
          @l.warn("\n#{ex}")
          @l.warn('SKIP: video deleted?')
          return
        elsif ex.response_code == '504'
          @l.error("\n#{ex}")
          @l.error('EXIT: timeout and retry')
          exit 1
        else
          @l.error("\n#{ex}")
          @l.error('EXIT: unknown error')
          exit 1
        end
      end
    end

    private

    def write(file, title, mode = 'w')
      @l.info { "#{title}" }
      open("#{DL_PATH}/#{title}", mode) { |x| x.write(file) }
      @l.info('success')
    end

    def param_nil?(params, key, warn_message)
      if params[key].nil?
        @l.warn("SKIP: #{key} not found (#{warn_message})")
        sleep(10)
        true
      else
        false
      end
    end

    def get_params(url)
      params = {}
      res = @agent.get(url)
      res.body.split('&').map do |r|
        k, v = r.split('=')
        params[k] = v
      end
      @l.debug { "response: \n#{res.body}" }
      params
    rescue Net::HTTP::Persistent::Error => ex
      @l.warn('get_params')
      @l.warn("\n#{ex}")
      @l.warn('retry')
      sleep(10)
      retry
    end

    def error_exit(message)
      @l.error { "#{message} ... exit" }
      exit 1
    end
  end
end
