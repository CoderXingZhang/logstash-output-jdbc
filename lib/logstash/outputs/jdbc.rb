# encoding: utf-8
require 'logstash/outputs/base'
require 'logstash/namespace'
require 'concurrent'
require 'stud/interval'
require 'java'
require 'logstash-output-jdbc_jars'

# Write events to a SQL engine, using JDBC.
#
# It is upto the user of the plugin to correctly configure the plugin. This
# includes correctly crafting the SQL statement, and matching the number of
# parameters correctly.
class LogStash::Outputs::Jdbc < LogStash::Outputs::Base
  STRFTIME_FMT = '%Y-%m-%d %T.%L'.freeze

  # Will never work, but only because it duplicates data (i.e. duplicate keys)
  # Will log a warning, but not retry.
  SQL_STATES_IGNORE = [
    ### Class: Unqualified Successful Completion
    # Success. This shouldn't get thrown, but JDBC driver quality varies, so who knows.
    0000,

    ### Class: Constraint Violation
    # Integrity constraint violation.
    23000,
    # A violation of the constraint imposed by a unique index or a unique constraint occurred.
    23505
  ].freeze

  # Will log an error, but not retry.
  SQL_STATES_FATAL = [
    ### Class: Data Exception
    # Character data, right truncation occurred. Field too small.
    22001,
    # Numeric value out of range.
    22003,
    # A null value is not allowed.
    22004,
    # Invalid datetime format.
    22007,
    # A parameter or host variable value is invalid.
    22023,
    # Character conversion resulted in truncation.
    22524,

    ### Constraint Violation
    # The insert or update value of a foreign key is invalid.
    23503,
    # The range of values for the identity column or sequence is exhausted.
    23522
  ].freeze

  config_name 'jdbc'

  # Driver class - Reintroduced for https://github.com/theangryangel/logstash-output-jdbc/issues/26
  config :driver_class, validate: :string

  # Does the JDBC driver support autocommit?
  config :driver_auto_commit, validate: :boolean, default: true, required: true

  # Where to find the jar
  # Defaults to not required, and to the original behaviour
  config :driver_jar_path, validate: :string, required: false

  # jdbc connection string
  config :connection_string, validate: :string, required: true

  # jdbc username - optional, maybe in the connection string
  config :username, validate: :string, required: false

  # jdbc password - optional, maybe in the connection string
  config :password, validate: :string, required: false

  # [ "insert into table (message) values(?)", "%{message}" ]
  config :statement, validate: :array, required: true

  # If this is an unsafe statement, use event.sprintf
  # This also has potential performance penalties due to having to create a
  # new statement for each event, rather than adding to the batch and issuing
  # multiple inserts in 1 go
  config :unsafe_statement, validate: :boolean, default: false

  # Number of connections in the pool to maintain
  config :max_pool_size, validate: :number, default: 5

  # Connection timeout
  config :connection_timeout, validate: :number, default: 10000

  # We buffer a certain number of events before flushing that out to SQL.
  # This setting controls how many events will be buffered before sending a
  # batch of events.
  config :flush_size, validate: :number, default: 1000

  # Set initial interval in seconds between retries. Doubled on each retry up to `retry_max_interval`
  config :retry_initial_interval, validate: :number, default: 2

  # Maximum time between retries, in seconds
  config :retry_max_interval, validate: :number, default: 128

  # Maximum number of sequential failed attempts, before we stop retrying.
  # If set to < 1, then it will infinitely retry.
  # At the default values this is a little over 10 minutes
  config :max_flush_exceptions, validate: :number, default: 10

  config :max_repeat_exceptions, obsolete: 'This has been replaced by max_flush_exceptions - which behaves slightly differently. Please check the documentation.'
  config :max_repeat_exceptions_time, obsolete: 'This is no longer required'
  config :idle_flush_time, obsolete: 'No longer necessary under Logstash v5'

  def register
    @logger.info('JDBC - Starting up')

    LogStash::Logger.setup_log4j(@logger)
    load_jar_files!

    @stopping = Concurrent::AtomicBoolean.new(false)

    @logger.warn('JDBC - Flush size is set to > 1000') if @flush_size > 1000

    if @statement.empty?
      @logger.error('JDBC - No statement provided. Configuration error.')
    end

    if !@unsafe_statement && @statement.length < 2
      @logger.error("JDBC - Statement has no parameters. No events will be inserted into SQL as you're not passing any event data. Likely configuration error.")
    end

    setup_and_test_pool!
  end

  def multi_receive(events)
    events.each_slice(@flush_size) do |slice|
      retrying_submit(slice)
    end
  end

  def teardown
    @pool.close
    super
  end

  def close
    @stopping.make_true
  end

  private

  def setup_and_test_pool!
    # Setup pool
    @pool = Java::ComZaxxerHikari::HikariDataSource.new

    @pool.setAutoCommit(@driver_auto_commit)
    @pool.setDriverClassName(@driver_class) if @driver_class

    @pool.setJdbcUrl(@connection_string)

    @pool.setUsername(@username) if @username
    @pool.setPassword(@password) if @password

    @pool.setMaximumPoolSize(@max_pool_size)
    @pool.setConnectionTimeout(@connection_timeout)

    validate_connection_timeout = (@connection_timeout / 1000) / 2

    # Test connection
    test_connection = @pool.getConnection
    unless test_connection.isValid(validate_connection_timeout)
      @logger.error('JDBC - Connection is not valid. Please check connection string or that your JDBC endpoint is available.')
    end
    test_connection.close
  end

  def load_jar_files!
    # Load jar from driver path
    unless @driver_jar_path.nil?
      raise Exception, 'JDBC - Could not find jar file at given path. Check config.' unless File.exist? @driver_jar_path
      require @driver_jar_path
      return
    end

    # Revert original behaviour of loading from vendor directory
    # if no path given
    jarpath = if ENV['LOGSTASH_HOME']
                File.join(ENV['LOGSTASH_HOME'], '/vendor/jar/jdbc/*.jar')
              else
                File.join(File.dirname(__FILE__), '../../../vendor/jar/jdbc/*.jar')
              end

    @logger.debug('JDBC - jarpath', path: jarpath)

    jars = Dir[jarpath]
    raise Exception, 'JDBC - No jars found. Have you read the README?' if jars.empty?

    jars.each do |jar|
      @logger.debug('JDBC - Loaded jar', jar: jar)
      require jar
    end
  end

  def submit(events)
    connection = nil
    statement = nil
    events_to_retry = []

    begin
      connection = @pool.getConnection
    rescue => e
      log_jdbc_exception(e)
      return events
    end

    events.each do |event|
      begin
        statement = connection.prepareStatement(
          (@unsafe_statement == true) ? event.sprintf(@statement[0]) : @statement[0]
        )
        statement = add_statement_event_params(statement, event) if @statement.length > 1
        statement.execute
      rescue java.sql.SQLException => e
        if SQL_STATES_IGNORE.include? e.getSQLState
          @logger.warn('JDBC - Dropping event. Ignore-able exception (duplicate key most likely)', exception: e, event: event)
        elsif SQL_STATES_FATAL.include? e.getSQLState
          @logger.error('JDBC - Fatal SQL exception. Can never succeed. Dropping event.', exception: e, event: event)
        else
          log_jdbc_exception(e)
          events_to_retry.push(event)
        end
      rescue => e
        # Something else happened.
        log_jdbc_exception(e)
        events_to_retry.push(event)
      ensure
        statement.close unless statement.nil?
      end
    end

    connection.close unless connection.nil?

    events_to_retry
  end

  def retrying_submit(actions)
    # Initially we submit the full list of actions
    submit_actions = actions

    attempts = 0

    sleep_interval = @retry_initial_interval
    while submit_actions && !submit_actions.empty?
      return if !submit_actions || submit_actions.empty? # If everything's a success we move along
      # We retry whatever didn't succeed
      submit_actions = submit(submit_actions)

      # Everything was a success!
      break if !submit_actions || submit_actions.empty?

      if @max_flush_exceptions > 0
        attempts += 1

        if attempts > @max_flush_exceptions
          @logger.error("JDBC - max_flush_exceptions has been reached. #{submit_actions.length} events have been unable to be sent to SQL and are being dropped. See previously logged exceptions for details.")
          break
        end
      end

      # If we're retrying the action sleep for the recommended interval
      # Double the interval for the next time through to achieve exponential backoff
      Stud.stoppable_sleep(sleep_interval) { @stopping.true? }
      sleep_interval = next_sleep_interval(sleep_interval)
    end
  end

  def add_statement_event_params(statement, event)
    @statement[1..-1].each_with_index do |i, idx|
      case event.get(i)
      when Time
        # See LogStash::Timestamp, below, for the why behind strftime.
        statement.setString(idx + 1, event.get(i).strftime(STRFTIME_FMT))
      when LogStash::Timestamp
        # XXX: Using setString as opposed to setTimestamp, because setTimestamp
        # doesn't behave correctly in some drivers (Known: sqlite)
        #
        # Additionally this does not use `to_iso8601`, since some SQL databases
        # choke on the 'T' in the string (Known: Derby).
        #
        # strftime appears to be the most reliable across drivers.
        statement.setString(idx + 1, event.get(i).time.strftime(STRFTIME_FMT))
      when Fixnum, Integer
        statement.setInt(idx + 1, event.get(i))
      when Float
        statement.setFloat(idx + 1, event.get(i))
      when String
        statement.setString(idx + 1, event.get(i))
      when true, false
        statement.setBoolean(idx + 1, event.get(i))
      else
        if event.get(i).nil? && i =~ /%\{/
          statement.setString(idx + 1, event.sprintf(i))
        else
          statement.setString(idx + 1, nil)
        end
      end
    end

    statement
  end

  def log_jdbc_exception(exception)
    current_exception = exception
    loop do
      @logger.warn('JDBC Exception encountered: Will automatically retry.', exception: current_exception)
      current_exception = current_exception.getNextException
      break if current_exception.nil?
    end
  end

  def next_sleep_interval(current_interval)
    doubled = current_interval * 2
    doubled > @retry_max_interval ? @retry_max_interval : doubled
  end
end # class LogStash::Outputs::jdbc
