#! /usr/bin/env ruby
# -*- coding: utf-8 -*-

require 'awesome_print'
require 'axlsx'
require 'base64'
require 'dotenv'
require 'faraday'
require 'logger'
require 'json'
require 'yaml'

exit(0) if defined? Ocra

Dotenv.load

class API
  class << self
    def get(url, params = {})
      resp = conn.get(url) do |req|
        # req.params['$select'] = 'id,name,city,country,group/descr'
        # req.params['$select'] = 'id_doc, tovar_doc'
        # req.params['$expand'] = 'tovar_doc'
        req.params.merge! params unless params.empty?
      end
      JSON.parse(resp.body)['d']['results']
    end

    private

    def host
      'https://api.myfreshcloud.com'
    end

    def conn
      @conn ||= Faraday.new(url: host) do |faraday|
        # faraday.use Faraday::Response::Logger
        faraday.headers['Authorization'] = auth_header
        faraday.adapter Faraday.default_adapter
      end
    end

    def auth_header
      @auth_header ||= 'Basic' + ' ' + Base64.encode64([ENV['API_ID'], ENV['API_KEY']].join(':'))
    end
  end
end

# ========= ASSOCIATIONS =========

def customers
  @customers ||= begin
    params = { '$select' => 'id, name, type/descr', '$expand' => 'type' }
    API.get('companies', params).each_with_object({}) do |customer, hash|
      hash[customer['id']] = customer
    end
  end
end

def users
  @users ||= begin
    params = { '$select' => 'id, name' }
    API.get('users', params).each_with_object({}) do |user, hash|
      hash[user['id']] = user
    end
  end
end

def document_states
  @document_states ||= API.get('priznak_documents').each_with_object({}) do |state, hash|
    hash[state['ID_PRIZNAK_DOCUMENT']] = state['PRIZNAK_DOCUMENT']
  end
end

def document_types
  @document_types ||= API.get('tip_documents').each_with_object({}) do |type, hash|
    hash[type['ID_TIP_DOCUMENT']] = type['TIP_DOCUMENT']
  end
end

def deals
  @deals ||= API.get('deal').each_with_object({}) do |deal, hash|
    merge_association deal, :deal_types, :id_type_deal, :type
    hash[deal['id_deal']] = deal
  end
end

def deal_types
  @deal_types ||= API.get('tip_deal').each_with_object({}) do |type, hash|
    hash[type['ID_TYPE_DEAL']] = type['TYPE_DEAL']
  end
end

def additional_fields
  @additional_fields ||= begin
    params = { '$filter' => "(field_name eq 'ADD_LIST_DOCUMENTS_N33') or (field_name eq 'ADD_LIST_DOCUMENTS_N34')" }
    API.get('additional_fields_document', params).each_with_object({}) do |field, hash|
      hash[field['object_id']] ||= {}
      field_hash = { field['field_name'] => field['field_value'] }
      hash[field['object_id']].merge! field_hash
    end
  end
end

def merge_association(object, collection, key, name = nil)
  id = key.is_a?(Symbol) ? object.delete(key.to_s) : key
  hash = name ? ({ name.to_s => send(collection)[id] }) : send(collection)[id]
  object.merge! hash if hash
  object
end

# ========= ASSOCIATIONS =========

def documents
  @documents ||= begin
    API.get('documents', document_params).map do |doc|
      merge_association doc, :customers,         :companies_id,   :customer
      merge_association doc, :users,             :id_manager,     :manager
      merge_association doc, :deals,             :id_deal,        :deal
      merge_association doc, :document_types,    :id_tip_doc,     :type
      merge_association doc, :document_states,   :id_priznzk_doc, :state
      merge_association doc, :additional_fields, doc['id_doc']
    end
  end
end

def document_params
  {
    '$select'  => 'id_doc, companies_id, id_manager, id_tip_doc, id_priznzk_doc, id_deal, summa, number_doc, data_doc, tovar_doc',
    '$expand'  => 'tovar_doc',
    '$orderby' => 'data_doc',
    '$filter'  => date_filter
  }
end

def date_filter
  [
    "data_doc ge datetime'#{dates[:from]}'",
    "data_doc le datetime'#{dates[:to]}'"
  ].join(' and ')
end

def dates
  {
    from: (time_parse(config['dates']['from']) || beginning_of_month).utc.strftime('%FT%T%:z'),
    to:   (time_parse(config['dates']['to']) || Time.now).utc.strftime('%FT%T%:z')
  }
end

def time_parse(date)
  Time.parse date
rescue
  nil
end

def beginning_of_month
  now = Time.now
  Time.new(now.year, now.month, 1)
end

def config
  @config ||= YAML.load File.open('config.yml')
end

def headers
  @headers ||= config['headers']
end

def document_rows(document)
  document['tovar_doc']['results'].map do |product|
    [
      document['number_doc'],
      format_date(document['data_doc']),
      document['type'],
      document['state'],
      document['summa'],
      document['paid'],
      format_custom_date(document['ADD_LIST_DOCUMENTS_N33']),
      format_custom_date(document['ADD_LIST_DOCUMENTS_N34']),
      document['customer']['name'],
      document['manager']['name'],
      deal_label(document['deal']),
      document['customer']['type']['descr'],
      product['tovar'],
      product['kol_vo'],
      product['price'],
      product['summa']
    ]
  end
rescue
  p document
  raise
end

def format_date(date)
  return unless date
  Date.parse(date)
end

def format_custom_date(date)
  return unless date
  match = /^(?<month>[а-я]{3})\s+(?<day>\d{1,2})\s+(?<year>\d{4})/.match date
  Date.parse([
    match['month'],
    match['day'].rjust(2, '0'),
    match['year']
  ].join(' '))
end

def deal_label(deal)
  return unless deal
  [Date.parse(deal['date_start']).strftime('%d.%m.%Y'), deal['type'], deal['id_deal']].join ' '
end

def define_styles(sheet)
  header = sheet.styles.add_style bg_color: '5B9BD5', fg_color: 'FFFFFF', sz: 10, b: true
  @styles = { header: header }
end

def filename
  format '%{name}-%{date}.%{ext}',
         name: 'export',
         date: Date.today.strftime('%d-%m-%Y'),
         ext: 'xlsx'
end

def write_file
  Axlsx::Package.new do |p|
    wb = p.workbook
    wb.add_worksheet do |sheet|
      define_styles sheet
      sheet.add_row headers, style: @styles[:header]

      documents.each do |document|
        document_rows(document).each do |row|
          sheet.add_row row
        end
      end
    end
    p.serialize filename
  end
end

def call
  write_file
end

logo = <<-STR
  ___  __  __ _____    ____                      _ _
 / _ \\|  \\/  |_   _|  / ___|___  _ __  ___ _   _| | |_
| | | | |\\/| | | |   | |   / _ \\| '_ \\/ __| | | | | __|
| |_| | |  | | | |   | |__| (_) | | | \\__ \\ |_| | | |_
 \\___/|_|  |_| |_|    \\____\\___/|_| |_|___/\\__,_|_|\\__| v#{File.read('.version').strip}
STR

$logger = Logger.new 'log'
$logger.level = Logger::ERROR

begin
  $logger.debug 'Start'
  puts logo
  call
  $logger.debug 'Done'
  puts 'File has been successfully created. Press any key to exit.'
rescue Exception => e
  puts 'Process has been failed. See log file for more information.'
  $logger.error e.message
  $logger.error e.backtrace.join("\n")
ensure
  $logger.debug 'finish'
  gets
end
