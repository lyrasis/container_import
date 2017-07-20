require 'csv'
require 'jsonmodel'
require_relative 'lib/container_import'

reporter = ContainerImport::Reporter.new(
  "/tmp/aspace/status.txt",
  "/tmp/aspace/error.txt"
)
reporter.report "Import start: #{Time.now}\n-----"

# resource  series  box barcode location  coordinate
container_csv_path = "/tmp/aspace/container.csv"
resource_cache     = Hash.new { |hash, key| hash[key] = {} }
component_cache    = Hash.new { |hash, key| hash[key] = {} }
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

# component including container in instance obj
def build_series(series, box, barcode, resource_uri)
  {
    "component_id" => "Series #{series}.",
    "instances"    => [ build_container(box, barcode) ],
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
      reporter.complain "Skipping row #{count} \"#{resource}:#{parsed}\" resource not found in ArchivesSpace!"
      next
    end

    unless box && barcode
      reporter.complain "Skipping row #{count} \"#{resource}:#{parsed}\" box and barcode values are required!"
      next
    end

    reporter.report "Row #{count} data: #{data}"

    repo_id     = resources[parsed][:repo_id]
    resource_id = resources[parsed][:id]

    RequestContext.open(:repo_id => repo_id, current_username: "admin") do
      r     = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:record] : Resource.get_or_die(resource_id)
      r_obj = resource_cache.has_key?(resource_id) ? resource_cache[resource_id][:model]  : Resource.to_jsonmodel(resource_id)

      if series
        series_id = find_series(repo_id, resource_id, series)
        if series_id
          reporter.report "Found series #{series} (#{series_id}) for resource #{resource} (#{resource_id})"
          found_box = false
          ao        = component_cache.has_key?(series_id) ? component_cache[series_id][:record] : ArchivalObject.get_or_die(series_id)
          ao_obj    = component_cache.has_key?(series_id) ? component_cache[series_id][:model]  : ArchivalObject.to_jsonmodel(series_id)

          # check direct children of series for container (box)
          child_ids = find_children_by_parent_id(series_id, repo_id, resource_id)
          child_ids.each do |child_id|
            child_ao  = component_cache.has_key?(child_id) ? component_cache[child_id][:record] : ArchivalObject.get_or_die(child_id)
            child_obj = component_cache.has_key?(child_id) ? component_cache[child_id][:model]  : ArchivalObject.to_jsonmodel(child_id)

            child_obj["instances"].each do |i|
              if i.has_key?("container") && i["container"]["type_1"] == "box" && i["container"]["indicator_1"] == box
                found_box = true
                i["container"]["barcode_1"] = barcode
                child_ao.update_from_json(JSONModel.JSONModel(:archival_object).from_hash(child_obj.to_hash))
                # refresh cache for this component
                component_cache[child_id][:record] = ArchivalObject.get_or_die(child_id)
                component_cache[child_id][:model]  = ArchivalObject.to_jsonmodel(child_id)
                reporter.report "Updated barcode for resource #{resource} (#{resource_id}), series #{series} (#{series_id}), box #{box} to #{barcode}"
              end
            end

            # child cache
            unless component_cache.has_key? child_id
              component_cache[child_id][:record] = child_ao
              component_cache[child_id][:model]  = child_obj
            end
          end

          # if no container matches then create container assoc with series
          unless found_box
            reporter.report "Did not find box for resource #{resource} (#{resource_id}), series #{series} (#{series_id}) with indicator #{box}"
            ao_obj["instances"] << build_container(box, barcode)
            ao.update_from_json(JSONModel.JSONModel(:archival_object).from_hash(ao_obj.to_hash))
            # refresh cache for this series
            component_cache[series_id][:record] = ArchivalObject.get_or_die(series_id)
            component_cache[series_id][:model]  = ArchivalObject.to_jsonmodel(series_id)
            reporter.report "Created container box #{box} with barcode #{barcode} for series #{series} (#{series_id}) in resource #{resource} (#{resource_id})"
          end
        else
          # series was not found so create series level component with container
          reporter.report "Did not find series #{series} for resource #{resource} (#{resource_id})"
          series_obj = build_series(series, box, barcode, r_obj["uri"])
          series_rec = ArchivalObject.create_from_json(JSONModel.JSONModel(:archival_object).from_hash(series_obj))
          series_id  = series_rec.id
          component_cache[series_id][:record] = ArchivalObject.get_or_die(series_id)
          component_cache[series_id][:model]  = ArchivalObject.to_jsonmodel(series_id)
          reporter.report "Created series #{series} (#{series_id}) in resource #{resource} (#{resource_id}) with box indicator #{box} and barcode #{barcode}"
        end

        # series cache
        unless component_cache.has_key? series_id
          component_cache[series_id][:record] = ao
          component_cache[series_id][:model]  = ao_obj
        end
      else
        # no series provided in csv so create container associated with resource
        r_obj["instances"] << build_container(box, barcode)
        r.update_from_json(JSONModel.JSONModel(:resource).from_hash(r_obj.to_hash))
        # refresh cache for this resource
        resource_cache[resource_id][:record] = Resource.get_or_die(resource_id)
        resource_cache[resource_id][:model]  = Resource.to_jsonmodel(resource_id)
        reporter.report "Created container box #{box} with barcode #{barcode} for resource #{resource} (#{resource_id})"
      end

      # resource cache
      unless resource_cache.has_key? resource_id
        resource_cache[resource_id][:record] = r
        resource_cache[resource_id][:model]  = r_obj
      end
    end

    reporter.report "-----"
    # break
  end
end

reporter.report "Import done: #{Time.now}\n-----"
reporter.finish