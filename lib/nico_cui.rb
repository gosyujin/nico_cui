# -*-coding: utf-8 -*-
require "nico_cui/version"
require "mechanize"
require "pit"
require "net/http"
require "zlib"
require "uri"
require "pp"

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
  Login_Url     = "https://secure.nicovideo.jp/secure/login_form"
  Videoinfo_Url = "http://ext.nicovideo.jp/api/getthumbinfo"
  Comment_Url   = "http://flapi.nicovideo.jp/api/getflv"
  Thread_Id_Url = "http://flapi.nicovideo.jp/api/getthreadkey"

  Config = YAML.load_file("_config.yml")
  #require 'pp' ; pp Config
  Core = Pit.get(Config["pit_id"])

  Dl_Url_Reg = "http://www.nicovideo.jp/watch/"
  Gz_Magic_Num = ["1f8b"]
  # not smXXXXXXX
  Ignore_Number = "sm"
  Ignore_Title = "\r\n\t\t\t\t\t\t\t\t"

  def gets
    FileUtils.mkdir_p(Config["path"])
    @exist_files = []
    Dir.glob("#{Config["path"]}/*").each do |file|
      @exist_files << File::basename(file, ".*")
    end
    @exist_files.uniq!

    login
    dl_cores = open_mypage

    puts "INFO: get description, tags"
    dl_cores.each do |dl|
      sleep(1)

      dl = get_videoinfo(dl)
      download(dl)
      puts "================="
    end
  end

  # return: login page's title
  def login
    puts "INFO: open login page..."

    @agent = Mechanize.new
    login_page = @agent.get(Login_Url)
    login_form = login_page.forms.first
    login_form["mail_tel"] = Core["id"]
    login_form["password"] = Core["password"]
    @agent.submit(login_form).title
  end

  def open_mypage
    puts "INFO: open my page..."

    my_list = @agent.page.link_with(:href => /\/my\/top/).click

    puts "INFO: search link '#{Dl_Url_Reg}' in my page"
    dl_cores = []
    my_list.links.each do |link|
      url = link.node.values[0]
      if url.match(/#{Dl_Url_Reg}/) then
        dl = {}
        dl["title"]  = link.node.children.text
        dl["url"]    = url
        dl["number"] = $'
        next if dl["title"]        == Ignore_Title
        next if dl["number"].include? Ignore_Number
        dl_cores << dl
        print "\rINFO: #{dl_cores.size} videos"
      end
    end
    print "\n"

    dl_cores
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
    puts "INFO: download target: #{dl["title"]}"

    res = @agent.get("#{Comment_Url}/#{dl["number"]}")
    params = {}
    res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }

    thread_id      = params["thread_id"]
    user_id        = params["user_id"]
    minutes        = (params["l"].to_i / 60 ) + 1

    if params["ms"].nil? then
      puts "WARN: SKIP: message_server not found"
      return
    end
    message_server = URI.decode(params["ms"])

    if params["url"].nil? then
      puts "WARN: SKIP: url not found (Pay video ?)"
      return
    end
    video_server   = URI.decode(params["url"])

    res = @agent.get("#{Thread_Id_Url}?thread=#{thread_id}")
    res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }

    if params["threadkey"].nil? then
      puts "WARN: SKIP: threadkey not found"
      return
    end
    thread_key     = params["threadkey"]
    force_184      = params["force_184"]

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

    begin
      puts "INFO: comment get"
      @agent.content_encoding_hooks << lambda do |httpagent, uri, response, body_io|
        response['content-encoding'] = nil
      end
      res = @agent.post_data(message_server, xml)
    rescue Net::HTTP::Persistent::Error => ex
      puts "WARN: #{ex}"
      puts "WARN: retry"
      sleep(1)
      retry
    end

    begin
      # res.body: \x1F\x8B\.... => gzip
      if StringIO.open(res.body).read(2).unpack("H*") == Gz_Magic_Num then
        puts "INFO: comment format: gzip"
        content = StringIO.open(res.body, "rb") { |r| Zlib::GzipReader.wrap(r).read }
        open("#{Config["path"]}/#{dl["title"]}.xml", "w") { |x| x.write(content) }
      else
        puts "INFO: comment format: xml"
        content = res.body
        open("#{Config["path"]}/#{dl["title"]}.xml", "w") { |x| x.write(content) }
      end
    rescue Zlib::GzipFile::Error => ex
      puts "WARN: #{ex}"
      puts "WARN: res.body: #{res.body}"
      return
    end
    puts "INFO: comment complete"

    if @exist_files.include?(dl["title"]) then
      puts "SKIP: already exist"
      return
    end

    puts "INFO: download start"
    @agent.get(dl["url"])
    @agent.download(video_server, "#{Config["path"]}/#{dl["title"]}.mp4")
    puts "INFO: download complete"

    puts "INFO: write title, tags, description"
    open("#{Config["path"]}/#{dl["title"]}.html", "w") { |x| x.write(dl) }
    puts "INFO: write complete"
  end
end

NicoCui::gets
