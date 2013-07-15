require "nico_cui/version"
require "mechanize"
require "pit"
require "net/http"
require "uri"
require "pp"

module NicoCui
  extend self
  Login_Url = "https://secure.nicovideo.jp/secure/login_form"
  Dl_Url_Reg = "http://www.nicovideo.jp/watch/"

  # not smXXXXXXX
  Ignore_Number = "sm"
  Ignore_Title = "\r\n\t\t\t\t\t\t\t\t"

  Core = Pit.get("nico")

  def gets
    puts "INFO: open login page..."
    agent = Mechanize.new
    login_page = agent.get(Login_Url)
    login_form = login_page.forms.first
    login_form["mail_tel"] = Core["id"]
    login_form["password"] = Core["password"]
    agent.submit(login_form)

# mylist page
    puts "INFO: open my page..."
    my_list = agent.page.link_with(:href => /\/my\/top/).click

    dl_cores = []
    my_list.links.each do |link|
      url = link.node.values[0]
      if url.match(/#{Dl_Url_Reg}/) then
        dl = {}
        dl["title"] = link.node.children.text
        dl["url"] = url
        dl["number"] = $'
        next if dl["title"] == Ignore_Title
        next if dl["number"].include? Ignore_Number
        dl_cores << dl
      end
    end
    #pp dl_cores

    puts "INFO: get description, tags and comments"
# get description and tags
    dl_cores.each do |dl|
      res = agent.get("http://ext.nicovideo.jp/api/getthumbinfo/#{dl["number"]}")
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

# get message server
      res = agent.get("http://flapi.nicovideo.jp/api/getflv/#{dl["number"]}")
      params = {}
      res.body.split("&").map { |r| k,v = r.split("="); params[k] = v }

      thread_id = params["thread_id"]
      user_id = params["user_id"]
      message_server = URI.decode(params["ms"])
      if params["url"].nil? then
        puts "SKIP: url not found: #{thread_id} #{dl["title"]}"
        next
      end
      video_server = URI.decode(params["url"])

      res = agent.get("http://flapi.nicovideo.jp/api/getthreadkey?thread=#{thread_id}")
      thread_key = res.body

      xml = <<-EOH
        <thread
          thread=#{thread_id}
          version="20061206"
          res_from="-1000"
          user_id=#{user_id}
          #{thread_key}
          force_184="1"
        />
      EOH

      # Mechanize cannot include request body?
      #res = agent.post_data(message_server, xml)
      #pp res
      dl["comments"] = []

# download before fake watch
      puts "INFO: download start: #{dl["title"]}"
      dl["video_server"] = video_server
      agent.get(dl["url"])
      agent.download(dl["video_server"], "#{dl["title"]}.mp4")
      puts "INFO: download complete"
    end
  end
end

NicoCui::gets
