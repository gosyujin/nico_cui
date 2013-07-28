# -*-coding: utf-8 -*-
require "nico_cui/version"
require "mechanize"
require "pit"
require "net/http"
require "zlib"
require "uri"
require "logger"

class Mechanize
  def post_data(uri, data, query = {}, headers = {})
    return request_with_entity(:post, uri, query, headers) if String === query

    node = {}
    # Create a fake form
    class << node
      def search(*args); []; end
    end
    node['method'] = 'POST'
    #node['enctype'] = 'application/x-www-form-urlencoded'
    node['enctype'] = 'text/xml'

    form = Form.new(node)

    query.each { |k, v|
      if v.is_a?(IO)
        form.enctype = 'multipart/form-data'
        ul = Form::FileUpload.new({'name' => k.to_s},::File.basename(v.path))
        ul.file_data = v.read
        form.file_uploads << ul
      else
        form.fields << Form::Field.new({'name' => k.to_s},v)
      end
    }

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

module NicoCui
  extend self
  @l = Logger.new(STDOUT)
  @l.datetime_format ="%Y-%m-%dT%H:%M:%S "
  @l.level = Logger::INFO

  LOGIN_URL        = "https://secure.nicovideo.jp/secure/login_form"
  VIDEOINFO_URL    = "http://ext.nicovideo.jp/api/getthumbinfo"
  COMMENT_URL      = "http://flapi.nicovideo.jp/api/getflv"
  THREAD_ID_URL    = "http://flapi.nicovideo.jp/api/getthreadkey"

  CONFIG           = YAML.load_file("_config.yml")
  CORE             = Pit.get(CONFIG["pit_id"])
  DL_PATH          = CONFIG["path"]

  DL_URL           = "http://www.nicovideo.jp/watch/"
  MY_PAGE_TOP      = "/my/top"
  PAST_NICO_REPORT = "next-page-link"
  GZIP_MAGICNUM    = ["1f8b"]
  LOGIN_FAILED     = "Log into Niconico"

  # not download smXXXXXXX
  IGNORE_NUMBER    = "sm"
  IGNORE_TITLE     = "\r\n\t\t\t\t\t\t\t\t"

  @exist_files = []
  @dl_cores    = []

  def gets
    FileUtils.mkdir_p(DL_PATH)
    Dir.glob("#{DL_PATH}/*").each do |file|
      @exist_files << File::basename(file, ".*")
    end
    @exist_files.uniq!

    @l.info("open login page")
    login
    error_exit("login failed?(check mail and password)") if login.title == LOGIN_FAILED

    @l.info("open my page")
    my_top_link = @agent.page.link_with(:href => /#{MY_PAGE_TOP}/)
    error_exit("not found my page link: #{MY_PAGE_TOP}") if my_top_link.nil?
    @l.info{ "search link '#{DL_URL}' in #{MY_PAGE_TOP}" }
    my_list = my_top_link.click

    @l.info("get video title and link from #{MY_PAGE_TOP}")
    check_mypage(my_list)
    print "\n"

    @l.info("get description, tags")
    @l.info("================================")
    @l.debug { "@dl_cores: \n#{@dl_cores}" }
    @dl_cores.each do |dl|
      sleep(10)

      dl = get_videoinfo(dl)
      download(dl)
      @l.info("================================")
    end
  end

  # return: login page's title
  def login
    @agent = Mechanize.new
    login_page = @agent.get(LOGIN_URL)
    login_form = login_page.forms.first
    login_form["mail_tel"] = CORE["id"]
    login_form["password"] = CORE["password"]
    @agent.submit(login_form)
  end

  def check_mypage(my_list)
    my_list.links.each do |link|
      url = link.node.values[0]
      if url.match(/#{DL_URL}/) then
        dl = {}
        dl["title"]  = link.node.children.text
        dl["url"]    = url
        dl["number"] = $'
        next if dl["title"]        == IGNORE_TITLE
        next if dl["number"].include? IGNORE_NUMBER
        @dl_cores << dl
        print "\r#{@dl_cores.size} videos: #{dl["title"]}"
      elsif url.match(/#{PAST_NICO_REPORT}/) then
        past_url = link.node.values[1]
        check_mypage(@agent.get(past_url))
      end
    end
  end

  def get_videoinfo(dl)
    res = @agent.get("#{VIDEOINFO_URL}/#{dl["number"]}")
    res.xml.children.children.children.each do |child|
      case child.name
      when "description"
        dl["description"] = child.content
      when "tags"
        tags = []
        child.children.each do |c|
          case c.name
          when "tag"
            tags << c.content
          end
        end
        dl["tags"] = tags
      end
    end
    dl
  end

  def download(dl)
    dl["title"] = dl["title"].gsub(/\//, "-")
    @l.info{ "download target: #{dl["title"]}" }
    params = {}

    comment_url = "#{COMMENT_URL}/#{dl["number"]}"
    params = get_params(comment_url)
    @l.debug { "comment_url : #{comment_url}"}

    return if param_nil?(params, "ms", "Pay video?")
    return if param_nil?(params, "url", "Pay video?")
    message_server = URI.decode(params["ms"])
    video_server   = URI.decode(params["url"])
    thread_id      = params["thread_id"]
    user_id        = params["user_id"]
    minutes        = (params["l"].to_i / 60 ) + 1

    thread_id_url = "#{THREAD_ID_URL}?thread=#{thread_id}"
    params.merge!(get_params(thread_id_url))
    @l.debug { "thread_id_url : #{thread_id_url}"}

    return if param_nil?(params, "threadkey", "Pay video?")
    thread_key = params["threadkey"]
    force_184  = params["force_184"]

    @l.info("title, tags, description write")
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
    @l.debug { "xml: \n#{xml}"}

    @l.info("comment get")
    begin
      @agent.content_encoding_hooks << lambda do |httpagent, uri, response, body_io|
        response['content-encoding'] = nil
      end
      res = @agent.post_data(message_server, xml)
    rescue Net::HTTP::Persistent::Error => ex
      @l.error("\n#{ex}")
      @l.error("retry")
      sleep(10)
      retry
    end

    begin
      # res.body: \x1F\x8B\.... => gzip
      if StringIO.open(res.body).read(2).unpack("H*") == GZIP_MAGICNUM then
        @l.debug("comment format: gzip")
        content = StringIO.open(res.body, "rb") { |r| Zlib::GzipReader.wrap(r).read }
      else
        @l.debug("comment format: xml")
        content = res.body
      end
      write(content, "#{dl["title"]}.xml")
    rescue Zlib::GzipFile::Error => ex
      @l.error("\n#{ex}")
      @l.debug("res.body: \n#{res.body}")
      return
    end

    @l.info("download start")
    if @exist_files.include?(dl["title"]) then
      @l.info("SKIP: video already exist")
      return
    end

    @agent.get(dl["url"])
    @agent.download(video_server, "#{DL_PATH}/#{dl["title"]}.mp4")
    @l.info("complete")
  end

private
  def write(file, title, mode="w")
    @l.info{ "#{title}" }
    open("#{DL_PATH}/#{title}", mode) { |x| x.write(file) }
    @l.info("seccess")
  end

  def param_nil?(params, key, warn_message)
    if params[key].nil? then
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
    res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }
    @l.debug { "response: \n#{res.body}"}
    params
  end

  def error_exit(message)
    @l.error { "#{message} ... exit" }
    exit 1
  end
end

NicoCui::gets
