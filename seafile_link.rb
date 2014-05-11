#!/usr/bin/ruby
# Requirements:
# - httparty gem
# - clipboard gem
# - zenity console program: apt-get install zenity
# - xclip console program: apt-get install xclip


require 'httparty'
require 'clipboard'
require 'pp'
require 'logger'

SEAFILE_SERVER = 'https://cloud.seafile.com'
ACCESS_TOKEN_PATH = File.expand_path('~/.seafile_token')

# module to use a global initialized logger in any class
# use "include Logging" in a class to use it
module Logging
  # This method is mixed into the classes
  def logger
    Logging.get_logger
  end

  # Returns the earlier created logger or creates new one
  def self.get_logger
    @logger ||= Logging.create_logger
  end

  # Create a new logger
  def self.create_logger
    l = Logger.new(STDOUT)
    #l = Logger.new(File.expand_path('~/seafile_link.log'))
    l.level = Logger::INFO
    #l.level = Logger::DEBUG
    return l
  end
end

# class to access seafile api
# API description: https://github.com/haiwen/seafile/wiki/Seafile-web-API
class Seafile
  include HTTParty
  include Logging

  def initialize(server)
    @login = false
    # Remove slash at the end (if there is one) and add /api2/
    self.class.base_uri(server.gsub(/\/+$/, '') + '/api2/')
  end

  # Set the authentification token to use
  def set_token(token)
    @login  = true
    self.class.headers 'Authorization' => 'Token ' + token
  end

  # Login with user name and password to obtain an access token
  def login(user, pass)
    res = self.class.post('/auth-token/', :body => {:username => user, :password => pass})
    hash = res.parsed_response
    if(hash.is_a? Hash and hash.has_key? 'token')
      set_token hash['token']
      return hash['token']
    elsif res.code == 403 or res.code == 400
      logger.debug res.inspect
      raise AuthError, 'Invalid credentials in login.'
    else
      logger.debug res.inspect
      raise PermanentError, 'Connection error in login.'
    end
  end

  # Create a link for file in repo
  # @param repo is the repo id
  # @param file is the relative path to the file in the repo starting with a slash
  def create_link(repo, file)
    raise AuthError, 'No auth token present' if @login.nil?
    res = self.class.put("/repos/#{repo}/file/shared-link/", :body => {:p => file})
    if res and res.code == 201 and res.headers['location']
      return res.headers['location']
    elsif res.code == 403
      logger.debug res.inspect
      raise AuthError, 'Invalid credentials in create_link.'
    else
      logger.debug res.inspect
      raise PermanentError, 'Connection error in create_link.'
    end
  end

  # List all repos of the user
  def repos
    raise AuthError, 'No auth token present' if @login.nil?
    res = self.class.get('/repos/')
    if res and res.parsed_response.is_a? Array
      return res.parsed_response
    elsif res.code == 403
      logger.debug res.inspect
      raise AuthError, 'Invalid credentials in repos.'
    else
      logger.debug res.inspect
      raise PermanentError, 'Connection error in repos.'
    end
  end
end

# Simple wrapper for zenity
class ZenityGui
  def initialize(title)
    @title = "--title='#{title}'"
  end

  def progress_start
    @progress = IO.popen("zenity #{@title} --progress  --auto-close --auto-kill --text='Link wird erstellt.'", 'w')
  end

  def progress_report(percentage, text = nil)
    return unless @progress

    @progress.puts percentage.to_i if percentage
    @progress.puts "# #{text}" if text
  end

  def progress_stop
    if @progress and !@progress.closed?
      progress_report(100) # leads to auto close
      @progress.close unless @progress.closed?
    end
    @progress = nil
  end

  def info(text)
    `zenity #{@title} --info --text='#{text}'`
  end

  def error(text)
    `zenity #{@title} --error --text='#{text}'`
  end

  def ask(question, password = false)
    mode = (password ? '--password' : '--entry')
    res = `zenity #{@title} #{mode} --text='#{question}'`.strip
    if $?.success?
      return res
    else
      raise PermanentError, 'User abort'
    end
  end
end

# Custom Exceptions
class AuthError < StandardError; end
class PermanentError < StandardError; end

include Logging

# Search if any directory in the path of the given file matches a repository name
# If more than one repositories names match, the one at the deeper level is used
# This will only work, if repository names are unique in the file system ...so it is not the best way
def repo_for_path(repos, path)
  repo_id = nil
  file_path = nil
  repos.each do |repo|
    # this regex matches if the repo name is a directory in the path
    # it will match from the beginning of the string until and including the directory named like repo name
    regex =  /.*(^|\/)#{Regexp.escape(repo['name'])}\//
    if path =~ regex
      # remove the part matching regex (gives us the path relative to repository root)
      # and add a leading slash (second gsub)
      new_file_path = path.gsub(regex, '').gsub(/^\/*/, '/')
      if file_path.nil? or new_file_path.size < file_path.size
        # this repository relative path is the shortest, we have seen until now --> use it
        file_path = new_file_path
        repo_id = repo['id']
      end
    end
  end
  return repo_id, file_path
end

# the main actions to register a link and giving user feedback via gui
def register_link(path, gui)
  s = Seafile.new(SEAFILE_SERVER)
  force_login = false

  begin
    gui.progress_start
    login(gui, s, force_login)

    gui.progress_report(33, 'Searching repo')
    repo, file_path = repo_for_path(s.repos, path)
    raise "Cannot find a matching Seafile repo for #{path}!" unless repo and file_path

    gui.progress_report(66, 'Creating Link...')
    link = s.create_link(repo, file_path)

    gui.progress_report(100, 'Link Created')
    gui.progress_stop

    gui.info("#{link}")
    Clipboard.copy link
  rescue AuthError => e
    logger.error 'Auth Error:' + e.message
    logger.debug e
    force_login = true
    gui.progress_stop
    retry

  rescue PermanentError => e
    logger.error 'Permanent Error:' + e.message
    logger.debug e
    gui.error(e.message)

  rescue => e
    logger.error 'Unknown Error:' + e.message
    logger.debug e
    gui.error('Unknown Error:' + e.message)
  ensure
    gui.progress_stop
  end
end

# Perform a a login. If an access token is stored and force is false, this token is used.
# Otherwise, user and pass will be asked from user via gui
def login(gui, seafile, force = false)
  if force == false and File.exists? ACCESS_TOKEN_PATH
    logger.debug "Reading #{ACCESS_TOKEN_PATH}"
    token = File.open(ACCESS_TOKEN_PATH) {|f| f.readlines.first }
    seafile.set_token token
  else
    token = seafile.login(gui.ask('Seafile E-Mail Address:'), gui.ask('Seafile Password:', true))
    logger.debug "Writing #{ACCESS_TOKEN_PATH}"
    File.open(ACCESS_TOKEN_PATH, 'w') {|f| f.puts token}
  end
end

gui = ZenityGui.new('Seafile Link')
ARGV.each do |file|
  register_link(File.join(Dir.pwd, file), gui)
end

if ARGV.empty?
  gui.error "No files given."
end

