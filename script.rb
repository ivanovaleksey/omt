require 'base64'
require 'dotenv'
require 'faraday'
require 'json'

Dotenv.load

def host
  'https://api.myfreshcloud.com'
end

def secrets
  @secrets ||= YAML.load File.open('secrets.yml').read
end

def conn
  @conn ||= Faraday.new(url: host) do |faraday|
    faraday.request  :url_encoded
    faraday.adapter  Faraday.default_adapter
  end
end

def auth_header
  @auth_header ||= 'Basic' + ' ' + Base64.encode64([ENV['API_ID'], ENV['API_KEY']].join(':'))
end

resp = conn.get('companies') do |req|
  req.headers['Authorization'] = auth_header
  # req.params['$select'] = 'id,name,city,country,group/descr'
  req.params['$select'] = 'id,name,city,country,group'
  req.params['$expand'] = 'group'
end

json = JSON.load resp.body
p json['d']['results'].first
