# container import

Versions:

- 1.4.2

## Setup

Start MySQL:

```
### MYSQL
docker run -d \
  -p 3306:3306 \
  --name mysql \
  -e MYSQL_ROOT_PASSWORD=123456 \
  -e MYSQL_DATABASE=archivesspace \
  -e MYSQL_USER=archivesspace \
  -e MYSQL_PASSWORD=archivesspace \
  -v /tmp/mysql:/tmp/mysql \
  mysql:5.6 \
  --character-set-server=utf8 \
  --collation-server=utf8_unicode_ci \
  --innodb_buffer_pool_size=4G \
  --innodb_buffer_pool_instances=4
### END MYSQL
```

Restore database to `archivessapce`. Copy `container.csv` to `/tmp/aspace`.

Start ArchivesSpace:

```
docker run --name archivesspace -d \
  -p 8080:8080 \
  -p 8081:8081 \
  -p 8089:8089 \
  -p 8090:8090 \
  -e ARCHIVESSPACE_DB_TYPE=mysql \
  -e JAVA_OPTS="-Xms2g -XX:+DisableExplicitGC -XX:+UseConcMarkSweepGC -XX:+UseParNewGC -XX:+AggressiveOpts -XX:+UseFastAccessorMethods -XX:+UseBiasedLocking -XX:+UseCompressedOops -server" \
  -e ASPACE_JAVA_XMX="-Xmx2g" \
  -v $(pwd)/config:/archivesspace/config \
  -v $(pwd)/plugins:/archivesspace/plugins \
  -v /tmp/aspace:/tmp/aspace \
  --link mysql:db \
  lyrasis/archivesspace:1.4.2
```

Note: run the command from a directory containing:

- config/config.rb
- plugins/container_import/ # this plugin

The config file should have these settings:

```ruby
AppConfig[:db_url] = "jdbc:mysql://#{ENV['DB_PORT_3306_TCP_ADDR']}:3306/#{ENV.fetch('ARCHIVESSPACE_DB_NAME', 'archivesspace')}?user=#{ENV.fetch('ARCHIVESSPACE_DB_USER', 'archivesspace')}&password=#{ENV.fetch('ARCHIVESSPACE_DB_PASS', 'archivesspace')}&useUnicode=true&characterEncoding=UTF-8"
AppConfig[:enable_solr]     = false
AppConfig[:enable_indexer]  = false
AppConfig[:enable_frontend] = false
AppConfig[:enable_public]   = false
AppConfig[:plugins]         = ['container_import']
```

Logs are avaliable:

- /tmp/aspace/error.txt
- /tmp/aspace/status.txt

Container import will take hours.

When done start ArchivesSpace with standard configuration. Confirm:

- reindexing completes

Check database for duplicate barcodes with different `indicator_1` values. Update
so all barcodes are associated with a single `indicator_1` if necessary.

Stop and delete the `data` directory contents. Upgrade to `2.0.1`. Confirm:

- no upgrade errors
- reindexing completes

Check the `container_conversion` report (Background Jobs). There may be errors
not associated with the data import. If concerned / unsure perform an upgrade
on the database without the imported data and compare.

## TODO

- Locations

---