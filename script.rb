#! /usr/bin/env ruby

require 'active_support'
require 'active_support/core_ext'
require 'base64'
require 'dotenv'
require 'faraday'
require 'json'

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

def deals
  @deals ||= API.get('deal').map do |deal|
    merge_association deal, :deal_types, :id_type_deal, :type
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

def merge_association(object, collection, key, name)
  id = key.is_a?(Symbol) ? object.delete(key.to_s) : key
  object.merge! name.to_s => send(collection)[id]
end

# ========= ASSOCIATIONS =========

def documents
  @documents ||= begin
    API.get('documents', document_params).map do |doc|
      merge_association doc, :customers,         :companies_id, :customer
      merge_association doc, :users,             :id_manager,   :manager
      merge_association doc, :additional_fields, doc['id_doc'], :fields
    end
  end
end

def document_params
  {
    '$select'  => 'id_doc, companies_id, id_manager, id_priznzk_doc, summa, number_doc, data_doc, tovar_doc',
    '$expand'  => 'tovar_doc',
    '$orderby' => 'data_doc',
    '$filter'  => date_filter
  }
end

def date_filter
  [
    # "data_doc ge datetime'#{dates[:from]}'",
    "data_doc ge datetime'2016-06-27T18:19:22.527+03:00'",
    "data_doc le datetime'#{dates[:to]}'"
  ].join(' and ')
end

def dates
  {
    from: ENV['DATE_FROM'].presence || Time.now.beginning_of_week.to_s(:iso8601),
    to:   ENV['DATE_TO'].presence || Time.now.end_of_week.to_s(:iso8601)
  }
end

p documents.last 2
