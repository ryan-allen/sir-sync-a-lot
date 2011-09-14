require 'aws/s3'
require 'yaml'

class SirSyncalot
  def self.run!(*args)
    new(*args).run!
  end

  [:action, :config].each { |member| attr(member) }

  def initialize(action = "sync")
    @action = action
  end

  def run!
    validate_inputs!
    perform_action!
  end

  VERSION = '0.0.1'

private

  def validate_inputs!
    if setup_action? and config_exists?
      exit_with_error!("Can't make a setup, because there's already a configuration in '#{config_path}'.")
    elsif sync_action? and !config_exists?
      exit_with_error!("Can't make a sync, because there's no configuration, try '#{__FILE__} setup'.")
    end
  end

  def perform_action!
    if setup_action?
      aquire_lock! { perform_setup! }
    elsif sync_action?
      aquire_lock! { perform_sync! }
    elsif help_action?
      display_help!
    else
      exit_with_error!("Cannot perform action '#{@action}', try '#{__FILE__} help' for usage.")
    end
  end

  def setup_action?
    action == "setup"
  end

  def sync_action?
    action == "sync"
  end

  def help_action?
    action == "help"
  end

  def perform_setup!
    display("Hello! Ima ask you a few questions, and store the results in #{config_path} for later, OK?")

    config = {}

    config[:aws_access_key] = ask("What is the AWS access key?")
    config[:aws_secret_key] = ask("What is the AWS secret access key?")
    display("Just a sec, ima check that works...")
    if aws_credentials_valid?(config)
      display("Yep, all good.")
      config[:aws_dest_bucket] = ask("What bucket should we put your backups in? (If it doesn't exist I'll create it)")
      if bucket_exists?(config)
        if bucket_empty?(config)
          display("I found that the bucket already exists, and it's empty so I'm happy.")
        else
          exit_with_error!("I found the bucket to exist, but it's not empty. I can't sync to a bucket that is not empty.")
        end
      else
        display("The bucket doesn't exist, so I'm creating it now...")
        create_bucket(config)
        display("OK that's done.")
      end
    else
      exit_with_error!("I couldn't connect to S3 with the credentials you supplied, try again much?")
    end

    config[:local_file_path] = ask("What is the (absolute) path that you want to back up? (i.e. /var/www not ./www)")
    if !local_file_path_exists?(config)
      exit_with_error!("I find that the local file path you supplied doesn't exist, wrong much?")
    end

    config[:find_options] = ask("Do you have any options for find ? (e.g. \! -path \"*.git*). Press enter for none")

    display("Right, I'm writing out the details you supplied to '#{config_path}' for my future reference...")
    write_config!(config)
    display("You're good to go. Next up is '#{__FILE__} sync' to syncronise your files to S3.")
  end

  def aws_credentials_valid?(config = read_config())
    AWS::S3::Base.establish_connection!(:access_key_id => config[:aws_access_key], :secret_access_key => config[:aws_secret_key])
    begin
      AWS::S3::Service.buckets # AWS::S3 don't try to connect at all until you ask it for something.
    rescue AWS::S3::InvalidAccessKeyId => e
      false
    else
      true
    end
  end

  def bucket_exists?(config = read_config())
    AWS::S3::Bucket.find(config[:aws_dest_bucket])
  rescue AWS::S3::NoSuchBucket => e
    false
  end

  def bucket_empty?(config = read_config())
    AWS::S3::Bucket.find(config[:aws_dest_bucket]).empty?
  end

  def create_bucket(config = read_config())
    AWS::S3::Bucket.create(config[:aws_dest_bucket])
  end

  def local_file_path_exists?(config = read_config())
    File.exist?(config[:local_file_path])
  end

  def write_config!(config)
    open(config_path, 'w') { |f| YAML::dump(config, f) }
  end

  def read_config(reload = false)
    reload or !@config ? @config = open(config_path, 'r') { |f| YAML::load(f) } : @config
  end

  def perform_sync!
    display("Starting, performing pre-sync checks...")
    if !aws_credentials_valid?
      exit_with_error!("Couldn't connect to S3 with the credentials in #{config_path}.")
    end

    if !bucket_exists?
      exit_with_error!("Can't find the bucket in S3 specified in #{config_path}.")
    end

    if !local_file_path_exists?
      exit_with_error!("Local path specified in #{config_path} does not exist.")
    end

    create_tmp_sync_state

    if last_sync_recorded?
      display("Performing time based comparison...")
      files_modified_since_last_sync
    else
      display("Performing (potentially expensive) checksum comparison...")
      display("Generating local manifest...")
      generate_local_manifest
      display("Traversing S3 for remote manifest...")
      fetch_remote_manifest
      # note that we do not remove files on s3 that no longer exist on local host. this behaviour
      # may be desirable (ala rsync --delete) but we currently don't support it. ok? sweet.
      display("Performing checksum comparison...")
      files_on_localhost_with_checksums - files_on_s3
    end.each { |file| push_file(file) }

    finalize_sync_state

    display("Done like a dinner.")
  end

  def last_sync_recorded?
    File.exist?(last_sync_completed)
  end

  def create_tmp_sync_state
    `touch #{last_sync_started}`
  end

  def finalize_sync_state
    `cp #{last_sync_started} #{last_sync_completed}`
  end

  def last_sync_started
    ENV['HOME'] + "/.sir-sync-a-lot.last-sync.started"
  end

  def last_sync_completed
    ENV['HOME'] + "/.sir-sync-a-lot.last-sync.completed"
  end

  def files_modified_since_last_sync
    # '! -type d' ignores directories, in local manifest directories are spit out to stderr whereas directories pop up in this query
    `find #{read_config[:local_file_path]} #{read_config[:find_options]} \! -type d -cnewer #{last_sync_completed}`.split("\n").collect { |path| {:path => path } }
  end

  def update_config_with_sync_state(sync_start)
    config = read_config()
    config[:last_sync_at] = sync_start
    write_config!(config)
  end

  def generate_local_manifest
    `find #{read_config[:local_file_path]} #{read_config[:find_options]} -print0 | xargs -0 openssl md5 2> /dev/null > /tmp/sir-sync-a-lot.manifest.local`
  end

  def fetch_remote_manifest
    @remote_objects_cache = [] # instance vars feel like global variables somehow
    traverse_s3_for_objects(AWS::S3::Bucket.find(read_config[:aws_dest_bucket]), @remote_objects_cache)
  end

  def traverse_s3_for_objects(bucket, collection, n = 1000, upto = 0, marker = nil)
    objects = bucket.objects(:marker => marker, :max_keys => n)
    if objects.size == 0
      return
    else
      objects.each { |object| collection << {:path => "/#{object.key}", :checksum => object.etag} }
      traverse_s3_for_objects(bucket, collection, n, upto+n, objects.last.key)
    end
  end

  def files_on_localhost_with_checksums
    parse_manifest(local_manifest_path)
  end

  def files_on_s3
    @remote_objects_cache
  end

  def local_manifest_path
    "/tmp/sir-sync-a-lot.manifest.local"
  end

  def parse_manifest(location)
    if File.exist?(location)
      open(location, 'r') do |file|
        file.collect do |line|
          path, checksum = *line.chomp.match(/^MD5\((.*)\)= (.*)$/).captures
          {:path => path, :checksum => checksum}
        end
      end
    else
      []
    end
  end

  def push_file(file)
    # xfer speed, logging, etc can occur in this method
    display("Pushing #{file[:path]}...")
    AWS::S3::S3Object.store(file[:path], open(file[:path]), read_config[:aws_dest_bucket])
  rescue
    display("ERROR: Could not push '#{file[:path]}': #{$!.inspect}")
  end

  def aquire_lock!
    if File.exist?(lock_path)
      # better way is to write out the pid ($$) and read it back in, to make sure it's the same
      exit_with_error!("Found a lock at #{lock_path}, is another instance of #{__FILE__} running?")
    end

    begin
      system("touch #{lock_path}")
      yield
    ensure
      system("rm #{lock_path}")
    end
  end


  def display_help!
    display("Go help yourself buddy!")
  end

  def exit_with_error!(message)
    display("Gah! " + message)
    exit
  end

  def display(message)
    puts("[#{Time.now}] #{message}")
  end

  def ask(question)
    print(question + ": ")
    $stdin.readline.chomp # gets doesn't work here!
  end

  def config_exists?
    File.exist?(config_path)
  end

  def config_path
    ENV['HOME'] + "/.sir-sync-a-lot.yml"
  end

  def lock_path
    ENV['HOME'] + "/.sir-sync-a-lot.lock"
  end

end
