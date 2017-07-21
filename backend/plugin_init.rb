require 'csv'
require 'jsonmodel'
require_relative 'lib/container_import'

reporter = ContainerImport::Reporter.new(
  "/tmp/aspace/status.txt",
  "/tmp/aspace/error.txt"
)
reporter.report "# Import start: #{Time.now}\n-----"

# resource  series  box barcode location  coordinate
container_csv_path = "/tmp/aspace/container.csv"
resource_cache     = Hash.new { |hash, key| hash[key] = {} }
resource_groups    = Hash.new { |hash, key| hash[key] = {} }
series_groups      = Hash.new { |hash, key| hash[key] = {} }
count = 0

# container in instance obj
def build_container(box, barcode)
  {
    "instance_type" => "mixed_materials",
    "jsonmodel_type"=> "instance",
    "container"     => {
      "barcode_1"=> barcode,
      "indicator_1" => box,
      "type_1"=> "box",
      "jsonmodel_type"=>"container",
      "container_locations"=> []
    }
  }
end

# component only
def build_series(series, resource_uri)
  {
    "component_id" => "Series #{series}.",
    "level"        => "series",
    "resource"     => {"ref" => resource_uri},
    "title"        => "ContainerImport #{series}",
  }
end

def find_children_by_parent_id(parent_id, repo_id, resource_id)
  child_ids = []
  DB.open do |db|
    child_ids = db[:archival_object].where(
      parent_id: parent_id,
      repo_id: repo_id,
      root_record_id: resource_id,
    ).select(:id).map(:id)
  end  
  child_ids
end

# using series number in csv attempt to match it to a component id
def find_series(repo_id, resource_id, series)
  series_id = nil
  DB.open do |db|
    db[:archival_object].where(
      parent_id: nil,
      repo_id: repo_id,
      root_record_id: resource_id,
    ).select(:id, :component_id).each do |ao|
      unless ao[:component_id].nil?
        id = ao[:component_id].match(/(\d+)/)[0] rescue nil
        if id && id == series
          series_id = ao[:id]
          break
        end
      end
    end
  end
  series_id
end

# normalize aspace identifier json and mit csv identifier for equality
def parse_identifier(identifier)
  prefix = identifier.match(/^(A|M)C/)[0] rescue nil
  number = identifier.match(/\d{1,}/)[0].to_i.to_s rescue nil
  parsed = (prefix and number) ? "#{prefix}#{number}" : identifier
  parsed
end

# resources hash with { parsed_identifier: { id: x, repo_id: y } ... }
def parsed_resources
  resources = Hash.new { |hash, key| hash[key] = {} }
  DB.open do |db|
    db[:resource].select(:id, :identifier, :repo_id).each do |resource|
      json_identifier   = JSON.parse(resource[:identifier]).join
      parsed_identifier = parse_identifier(json_identifier)
      resources[parsed_identifier] = { id: resource[:id], repo_id: resource[:repo_id] }
    end
  end
  resources
end

ArchivesSpaceService.loaded_hook do
  resources = parsed_resources

  CSV.foreach(container_csv_path, headers: true) do |row|
    count += 1
    data            = row.to_hash
    data["barcode"] = data["barcode"].nil? ? nil : data["barcode"].gsub(/\D/, '')
    
    resource   = data["resource"]
    parsed     = parse_identifier(resource)
    series     = data["series"]
    box        = data["box"]
    barcode    = data["barcode"]
    location   = data["location"]
    coordinate = data["coordinate"]

    unless resources.has_key?(parsed)
      reporter.complain "Skipping row #{count} \"#{resource}:#{parsed}\" resource not found in ArchivesSpace"
      next
    end

    unless box && barcode
      reporter.complain "Skipping row #{count} \"#{resource}:#{parsed}\" box and barcode values are required"
      next
    end

    reporter.report "Preparing row #{count} data: #{data}"

    repo_id     = resources[parsed][:repo_id]
    resource_id = resources[parsed][:id]

    RequestContext.open(:repo_id => repo_id, current_username: "admin") do
      r     = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:record] : Resource.get_or_die(resource_id)
      r_obj = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:model]  : Resource.to_jsonmodel(resource_id)

      if series
        unless series_groups.has_key?(resource_id) and series_groups[resource_id].has_key?(series)
          series_groups[resource_id][series] = {}
          series_groups[resource_id][series][:id]           = nil
          series_groups[resource_id][series][:repo_id]      = repo_id
          series_groups[resource_id][series][:resource]     = resource
          series_groups[resource_id][series][:resource_id]  = resource_id
          series_groups[resource_id][series][:resource_uri] = r_obj["uri"]
          series_groups[resource_id][series][:data]         = []
          series_groups[resource_id][series][:exists]       = false
          series_groups[resource_id][series][:children]     = []
        end

        unless series_groups[resource_id][series][:id]
          series_id = find_series(repo_id, resource_id, series)
          if series_id
            series_groups[resource_id][series][:id]       = series_id
            series_groups[resource_id][series][:exists]   = true
            series_groups[resource_id][series][:children] = []
            child_ids = find_children_by_parent_id(series_id, repo_id, resource_id)
            child_ids.each do |child_id|
              # eat the cost of this up front
              series_groups[resource_id][series][:children] << [
                ArchivalObject.get_or_die(child_id),
                ArchivalObject.to_jsonmodel(child_id)
              ]
            end
          end
        end

        series_groups[resource_id][series][:data] << data
      else
        # no series provided so just group the resources to batch later
        unless resource_groups.has_key? resource_id
          resource_groups[resource_id][:repo_id] = repo_id
          resource_groups[resource_id][:data]    = []
        end
        resource_groups[resource_id][:data] << data
      end

      # resource cache
      unless resource_cache.has_key? resource_id
        resource_cache[resource_id][:record] = r
        resource_cache[resource_id][:model]  = r_obj
      end
    end

    reporter.report "-----"
  end
end

# Process series groups
reporter.report "# Import series groups: #{Time.now}\n-----"
series_groups.each do |resource_id, series_group|
  series_group.each do |series, group|
    reporter.report "Processing series #{series} for resource #{group[:resource]} (#{resource_id})"
    data_updated_child = []
    RequestContext.open(:repo_id => group[:repo_id], current_username: "admin") do
      # a) Create series that do not exist
      unless group[:exists]
        series_obj = build_series(series, group[:resource_uri])
        series_rec = ArchivalObject.create_from_json(JSONModel.JSONModel(:archival_object).from_hash(series_obj))
        group[:id] = series_rec.id
        reporter.report "Created series #{series} (#{group[:id]}) for resource #{group[:resource]} (#{resource_id})"
      end

      # b) Find children with matching boxes, update barcode and cleanup (remove used) data
      if group[:children].any?
        group[:data].each do |data|
          resource = data["resource"]
          barcode  = data["barcode"]
          box      = data["box"]

          group[:children].each do |child_pair|
            child, child_obj = child_pair

            child_obj["instances"].each do |i|
              if i.has_key?("container") && i["container"]["type_1"] == "box" && i["container"]["indicator_1"] == box
                i["container"]["barcode_1"] = barcode
                begin
                  child.update_from_json(JSONModel.JSONModel(:archival_object).from_hash(child_obj.to_hash))
                  reporter.report "Updated barcode for resource #{resource} (#{resource_id}), series #{series} (#{group[:id]}), box #{box} to #{barcode}"
                rescue Exception => ex
                  reporter.complain "Failed updating barcode for resource #{resource} (#{resource_id}), series #{series} (#{group[:id]}), box #{box} to #{barcode}: #{ex.message}"
                end
                data_updated_child << data
              end
            end
          end
        end
      end
      data_updated_child.each { |d| group[:data].delete(d) }

      # c) add container to series if data still present (i.e. data did not update existing container)
      next unless group[:data].any?
      ao     = ArchivalObject.get_or_die(group[:id])
      ao_obj = ArchivalObject.to_jsonmodel(group[:id])
      group[:data].each do |data|
        resource = data["resource"]
        box      = data["box"]
        barcode  = data["barcode"]
        ao_obj["instances"] << build_container(box, barcode)
        reporter.report "Added container box #{box} with barcode #{barcode} to series #{series} (#{group[:id]}) in resource #{resource} (#{resource_id})"
      end
      ao.update_from_json(JSONModel.JSONModel(:archival_object).from_hash(ao_obj.to_hash))
      reporter.report "Created containers for series #{series} (#{group[:id]})"
    end
    reporter.report "-----"
  end
end

# Process resource groups (resources without series, container at resource level)
reporter.report "# Import resource groups: #{Time.now}\n-----"
resource_groups.each do |resource_id, group|
  RequestContext.open(:repo_id => group[:repo_id], current_username: "admin") do
    r     = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:record] : Resource.get_or_die(resource_id)
    r_obj = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:model]  : Resource.to_jsonmodel(resource_id)
    group[:data].each do |data|
      resource = data["resource"]
      box      = data["box"]
      barcode  = data["barcode"]
      r_obj["instances"] << build_container(box, barcode)
      reporter.report "Added container box #{box} with barcode #{barcode} to resource #{resource} (#{resource_id})"
    end
    r.update_from_json(JSONModel.JSONModel(:resource).from_hash(r_obj.to_hash))
    reporter.report "Created containers for resource (#{resource_id})"
    reporter.report "-----"
  end
end

reporter.report "# Import done: #{Time.now}\n-----"
reporter.finish
