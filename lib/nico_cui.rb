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

  Login_Url        = "https://secure.nicovideo.jp/secure/login_form"
  Videoinfo_Url    = "http://ext.nicovideo.jp/api/getthumbinfo"
  Comment_Url      = "http://flapi.nicovideo.jp/api/getflv"
  Thread_Id_Url    = "http://flapi.nicovideo.jp/api/getthreadkey"

  Config           = YAML.load_file("_config.yml")
  Core             = Pit.get(Config["pit_id"])
  Dl_Path          = Config["path"]

  Dl_Url_Reg       = "http://www.nicovideo.jp/watch/"
  Past_Nico_Report = "next-page-link"
  Gz_Magic_Num     = ["1f8b"]
  # not download smXXXXXXX
  Ignore_Number    = "sm"
  Ignore_Title     = "\r\n\t\t\t\t\t\t\t\t"

  @exist_files = []
  @dl_cores    = []

  def gets
    FileUtils.mkdir_p(Dl_Path)
    Dir.glob("#{Dl_Path}/*").each do |file|
      @exist_files << File::basename(file, ".*")
    end
    @exist_files.uniq!

    @l.info("open login page")
    login

    @l.info("open my page")
    @l.info{ "search link '#{Dl_Url_Reg}' in my page" }
    my_list = @agent.page.link_with(:href => /\/my\/top/).click
    check_mypage(my_list)
    print "\n"

    @l.info("get description, tags")
    @l.info("=================")
    @l.debug { "@dl_cores: \n#{@dl_cores}" }
    @dl_cores.each do |dl|
      sleep(10)

      dl = get_videoinfo(dl)
      download(dl)
      @l.info("=================")
    end
  end

  # return: login page's title
  def login
    @agent = Mechanize.new
    login_page = @agent.get(Login_Url)
    login_form = login_page.forms.first
    login_form["mail_tel"] = Core["id"]
    login_form["password"] = Core["password"]
    @agent.submit(login_form).title
  end

  def check_mypage(my_list)
    my_list.links.each do |link|
      url = link.node.values[0]
      if url.match(/#{Dl_Url_Reg}/) then
        dl = {}
        dl["title"]  = link.node.children.text
        dl["url"]    = url
        dl["number"] = $'
        next if dl["title"]        == Ignore_Title
        next if dl["number"].include? Ignore_Number
        @dl_cores << dl
        print "\r#{@dl_cores.size} videos"
      elsif url.match(/next-page-link/) then
        past_url = link.node.values[1]
        check_mypage(@agent.get(past_url))
      end
    end

    @dl_cores
  end

  def get_videoinfo(dl)
    res = @agent.get("#{Videoinfo_Url}/#{dl["number"]}")
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

    res = @agent.get("#{Comment_Url}/#{dl["number"]}")
    params = {}
    res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }
    @l.debug { "comment_url response: \n#{res.body}"}

    thread_id      = params["thread_id"]
    user_id        = params["user_id"]
    minutes        = (params["l"].to_i / 60 ) + 1

    if params["ms"].nil? then
      @l.warn("message_server not found")
      sleep(10)
      return
    end
    message_server = URI.decode(params["ms"])

    if params["url"].nil? then
      @l.warn("SKIP: url not found (Pay video ?)")
      sleep(10)
      return
    end
    video_server   = URI.decode(params["url"])

    res = @agent.get("#{Thread_Id_Url}?thread=#{thread_id}")
    res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }
    @l.debug { "thread_id_url response: \n#{res.body}"}

    if params["threadkey"].nil? then
      @l.warn("SKIP: threadkey not found (Too access ?)")
      sleep(10)
      return
    end
    thread_key     = params["threadkey"]
    force_184      = params["force_184"]

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
      if StringIO.open(res.body).read(2).unpack("H*") == Gz_Magic_Num then
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
    @agent.download(video_server, "#{Dl_Path}/#{dl["title"]}.mp4")
    @l.info("success")
  end

private
  def write(file, title, mode="w")
    @l.info{ "#{title}" }
    open("#{Dl_Path}/#{title}", mode) { |x| x.write(file) }
    @l.info("seccess")
  end
end

NicoCui::gets
