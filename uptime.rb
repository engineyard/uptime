#!/usr/bin/ruby

require 'net/http' 
require 'net/https'
require 'uri'

DEBUG = false

TRIM_PERCENTAGE = 2.00
TRIM_FACTOR = TRIM_PERCENTAGE / 100

class Failure
 attr :date
 attr :error
 attr :response_time

 def initialize(date,error,response_time)
   @date          = date
   @error         = error
   @response_time = response_time
 end
end

class Detail
  include Comparable

  attr_accessor :id
  attr_accessor :name
  attr :failures

  def initialize(id,name)
    @id       = id
    @name     = name
    @failures = []
  end

  def add_failure(date,error,response_time)
    @failures << Failure.new(date,error,response_time)
  end

  def downs
    @failures.length
  end

  def total_timeslots(days)
    (days * 24 * 30).to_f
  end

  def uptime(days)
    ( total_timeslots(days) - downs ) / total_timeslots(days)
  end

  def uptime_to_s(days)
    '%3.3f' % (uptime(days) * 100)
  end

  def <=>(other) 
    downs <=> other.downs
  end 
end

def login
  url = URI.parse 'https://www.siteuptime.com/users/login.php'

  http = Net::HTTP.new(url.host, url.port)
  if url.scheme == 'https'
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end

  request = Net::HTTP::Post.new url.path
  request.set_form_data( { 'Email'    => USERNAME,
                           'Password' => PASSWORD,
                           'Action'   => 'Login',
                           'login'    => 'Login' } )

  response = http.request(request)
  response['set-cookie'].split('; ')[0]
end

def get_url(uri,cookie=nil)
  url = URI.parse uri
  http = Net::HTTP.new(url.host, url.port)
  if url.scheme == 'https'
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end
  request = Net::HTTP::Get.new(url.path + '?' + url.query)
  request['cookie'] = cookie unless cookie.nil?

  response = false
  tries    = 0

  while ! response and tries < 5 do
    tries += 1
    response = begin
                 response = http.request(request)
               rescue Timeout::Error, EOFError
                 STDOUT.print "retry \##{tries}, "; STDOUT.flush
                 response = false
               end
  end

  response
end

def ids_in(response)
  ids = []
  response.body.split("\n").each do |line|
    next unless line =~ /\/users\/reports.php\?Id=(\d+)/
    yield $1.to_i
  end
end

def get_ids(cookie)
  ids = []

  i = 1

  STDOUT.print "Getting ids from page "; STDOUT.flush

  loop do
    STDOUT.print "#{i}, "; STDOUT.flush

    url = "https://www.siteuptime.com/users/services.php?OrderBy=Name&Page=#{i}"

    response = get_url(url,cookie)

    before = ids.length

    ids_in(response) { |id| ids << id }

    ids.uniq!

    after = ids.length

    break if before == after or DEBUG

    i += 1
  end

  puts

  ids
end

def failures_in(response)
  count = 0
  date  = nil
  error = nil
  rtime = nil

  response.body.each do |line|
    next unless line =~ /<td nowrap='nowrap'>([^<]+)/ or
                ( count == 2 and line =~ /<td>([^<]+)/ )

    case count
      when 0: date  = $1
      when 1: error = $1
      when 2: rtime = $1
    end

    count += 1

    if count == 3
      yield date,error,rtime
      count = 0
    end
  end
end

def show_response(response)
  response.each do |key,value|
    puts "#{key}: #{value}"
  end
  puts response.body
end

collected_data = {}

USERNAME = ARGV[0]
PASSWORD = ARGV[1]

month1,day1,year1 = ARGV[2].chomp.split('/').collect { |s| s.to_i }
month2,day2,year2 = ARGV[3].chomp.split('/').collect { |s| s.to_i }

unless USERNAME
  puts 'Please enter SiteUpTime credentials...'

  puts 'USERNAME: '
  USERNAME = gets.chomp

  puts 'PASSWORD: '
  PASSWORD = gets.chomp

  puts 'Beginning date: (mm/dd/yyyy)'
  month1,day1,year1 = gets.chomp.split('/').collect { |s| s.to_i }

  puts 'Ending date: (mm/dd/yyyyy)'
  month2,day2,year2 = gets.chomp.split('/').collect { |s| s.to_i }
end

days = day2 - day1 + 1

puts "SiteUpTime report for #{month1}/#{day1}/#{year1}-#{month2}/#{day2}/#{year2}"
puts days.to_s + ' days, ' + Detail.new(0,'dummy').total_timeslots(days).to_s + ' total timeslots'

puts "Logging in..."
cookie = login

ids = get_ids(cookie)

STDOUT.print "Getting name and failures for id "; STDOUT.flush

ids.each do |id|
  STDOUT.print "#{id}, "; STDOUT.flush

  response = get_url("https://www.siteuptime.com/users/statistics.php?" +
                     "MonthYear=#{year1}-#{month1}&Day=#{day1}&"        +
                     "MonthYear2=#{year2}-#{month2}&Day2=#{day2}&"      +
                     "Action=FailuresHistory&UserServiceId=#{id.to_s}",
                     cookie)

  if response
    if response.body =~ /Failure Log for ([^<]+)/
      collected_data[id] = Detail.new(id,$1)

      failures_in(response) do |date,error,rtime|
        collected_data[id].add_failure(date,error,rtime)
      end
    end
  end
end

puts

collected_data.values.sort.reverse.each do |detail|
  puts "#{detail.name}: #{detail.downs} downs, #{detail.uptime_to_s(days)}"
end

aggregate_uptime = 0.0

collected_data.values.each do |detail|
  aggregate_uptime += ( detail.uptime(days) * 100 )
end

total_monitors = collected_data.keys.length.to_f

puts
puts "Average uptime across #{total_monitors.to_i} monitors: #{ '%3.3f' % (aggregate_uptime / total_monitors)}"

trim_count = (total_monitors * TRIM_FACTOR).to_i

# remove top TRIM_PERCENTAGE

puts
puts "Removing top #{TRIM_PERCENTAGE}% (#{trim_count}) of uptimes..."

collected_data.values.sort[0..trim_count].each do |detail|
  puts "Removing #{detail.name}: #{detail.downs} downs, #{detail.uptime_to_s(days)}"
  collected_data.delete(detail.id)
end

# remove bottom TRIM_PERCENTAGE

puts
puts "Removing bottom #{TRIM_PERCENTAGE}% (#{trim_count}) of uptimes..."

collected_data.values.sort.reverse[0..trim_count].each do |detail|
  puts "Removing #{detail.name}: #{detail.downs} downs, #{detail.uptime_to_s(days)}"
  collected_data.delete(detail.id)
end

aggregate_uptime = 0.0

collected_data.values.each do |detail|
  aggregate_uptime += ( detail.uptime(days) * 100 )
end

total_monitors = collected_data.keys.length.to_f

puts
puts "Average uptime after trimming top and bottom #{TRIM_PERCENTAGE}%, #{total_monitors.to_i} monitors: #{ '%3.3f' % (aggregate_uptime / total_monitors)}"
