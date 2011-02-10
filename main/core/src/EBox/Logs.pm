# Copyright (C) 2008-2010 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::Logs;

use strict;
use warnings;

#FIXME: readd EBox::LogObserver to have logadmin working
#use base qw(EBox::Module::Service EBox::LogObserver);
use base qw(EBox::Module::Service
            EBox::Model::ModelProvider EBox::Model::CompositeProvider
            EBox::Report::DiskUsageProvider);

use EBox::Global;
use EBox::Gettext;
use EBox::Loggerd;
use EBox::Config;
use EBox::Sudo;
use EBox::Exceptions::InvalidData;
use EBox::Exceptions::External;
use EBox::Exceptions::Internal;
use EBox::DBEngineFactory;
use EBox::Service;
use EBox::Logs::SlicedBackup;

use POSIX qw(ceil);

use constant LOG_DAEMON => 'ebox.loggerd';
use constant IMAGEPATH => EBox::Config::tmp . '/varimages';
use constant PIDPATH => EBox::Config::tmp . '/pids/';
use constant ENABLED_LOG_CONF_DIR => EBox::Config::conf  . '/logs';;
use constant ENABLED_LOG_CONF_FILE => ENABLED_LOG_CONF_DIR . '/enabled.conf';
use constant PG_DATA_DIR           => '/var/lib/postgres';


#       EBox::Module::Service interface
#

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'logs',
                                      printableName => __n('Logs'));

    bless($self, $class);
    return $self;
}

# Method: depends
#
#       Override EBox::Module::Base::depends
#
sub depends
{
    my $mods = EBox::Global->modInstancesOfType('EBox::LogObserver');
    my @names = map ($_->{name}, @$mods);
    return \@names;
}

sub _daemons
{
    return [
        {
            'name' => LOG_DAEMON,
            'precondition' => \&_loggerdPrecondition,
        }
    ];
}


#  Method: _loggerdPrecondition
#
#   loggerd daemon precondition, checks that a least one logger domain is
#   enabled
sub _loggerdPrecondition
{
    my ($self) = @_;
    my $enabled = $self->allEnabledLogHelpers();
    return @{ $enabled } > 0;
}

# Method: initialSetup
#
# Overrides:
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Run only the first time
    unless ($version) {
        my $cmd = qq{echo "CREATE LANGUAGE plpgsql" | sudo su postgres -c 'psql eboxlogs' > /dev/null 2>&1};
        system ($cmd);
    }
}

# Method: enableService
#
#   Used to enable a service. Overriddien to notify all LogObserver of the
#   changes.
#
# Parameters:
#
#   boolean - true to enable, false to disable
#
#  Overriddes:
#  <EBox::Module::service::enableService >
sub enableService
{
    my ($self, $status) = @_;
    defined $status or
        $status = 0;

    return unless ($self->isEnabled() xor $status);

    $self->SUPER::enableService($status);
    $self->_notifyLogEnable();
}

sub _notifyLogEnable
{
    my ($self, $status) = @_;
    my $modules = $self->getLogsModules();
    foreach my $module (@{ $modules }) {
        $module->enableLog($status);
    }
}

# Method: isRunning
#
# Overrides:
#
#      <EBox::Module::Service::isRunning>
#
sub isRunning
{
    my ($self) = @_;
    return $self->isEnabled();
}

# Method: _setConf
#
# Overrides:
#
#      <EBox::Module::Base::_setConf>
#
sub _setConf
{
    my ($self) = @_;

    $self->_saveEnabledLogsModules();
}

sub cleanup
{
    my ($self) = @_;
    $self->SUPER::revokeConfig();
}

#       Module API
sub modelClasses
{
    return [
            {
             class => 'EBox::Logs::Model::ConfigureLogDataTable',
             parameters => [
                            directory => 'configureLogTable',
                           ],
            },
            {
             class => 'EBox::Logs::Model::ForcePurge',
             parameters => [
                            directory => 'forcePurge',
                           ],
            },
            {
             class => 'EBox::Logs::Model::SelectLog',
            },
           ];
}


sub compositeClasses
{
    return [
            'EBox::Logs::Composite::ConfigureLog',
           ];
}

# Method: allEnabledLogHelpers
#
#       This function fetchs all the classes implemeting the interface
#       <EBox::LogHelper> which have been enabled for the user.
#
#       If the user has not configured anything yet, all are enabled
#       by default.
#
# Returns:
#
#       Array ref of objects <EBox::LogHelper>
#
sub allEnabledLogHelpers
{
    my ($self) = @_;

    my $global = EBox::Global->getInstance();

    my $enabledLogs = $self->_restoreEnabledLogsModules();

    # If there's no configuration stored it means the user
    # has not configured them yet. So by default, we enable all them
    unless (defined($enabledLogs)) {
        return $self->allLogHelpers();
    }

    my @enabledObjects;
    my @mods = @{$global->modInstancesOfType('EBox::LogObserver')};
    foreach my $mod (@mods) {
        if ($global->modEnabled($mod->name) and $enabledLogs->{$mod->name}) {
            my $logHelper = $mod->logHelper();
            defined $logHelper or
                next;
            push (@enabledObjects, $logHelper);
        }
    }

    return \@enabledObjects;
}

# Method: allLogHelpers
#
#       This function fetchs all the classes implemeting the interface
#       <EBox::LogHelper> and its associated fifo.
#
# Returns:
#
#       An array ref containing  hash references holding:
#
#               fifo - path to log file
#               classname - class name of the <EBox::LogHelper> implementation
#
sub allLogHelpers
{
    my ($self) = @_;

    my $global = EBox::Global->getInstance();

    my @objects;
    my @mods = @{$global->modInstancesOfType('EBox::LogObserver')};
    foreach my $mod (@mods) {
        my $obj = $mod->logHelper();
        next unless defined($obj);
        push @objects, $obj;
    }
    return \@objects;
}

sub getLogsModules
{
    my $global = EBox::Global->getInstance();

    return [grep { $_->configured() } @{$global->modInstancesOfType('EBox::LogObserver')}];
}

# Method: getAllTables
#
#       Get the table information from all modules which implements
#       the log observer
#
# Return:
#
#       hash ref - the table information indexed by table name (index)
#       as returned by <EBox::LogObserver::tableInfo> + 'helper'
#       component which is the module that implements the LogObserver
#       interface
#
sub getAllTables
{
    my ($self) = @_;
    my $global = EBox::Global->getInstance();
    my $tables;

    return $self->{tables} if ($self->{tables});

    foreach my $mod (@{getLogsModules()}) {
        my @tableInfos = @{ $self->getModTableInfos($mod) };

        foreach my $comp (@tableInfos) {
            $comp->{'helper'} = $mod;
            next unless ($comp);
            $tables->{$comp->{'index'}} = $comp;
        }
    }

    $self->{tables} = $tables;
    return $tables;
}

# Method: getTableInfo
#
#       Accessor to the table information from a log observer
#
# Returns:
#
#       hash ref - the table information returned by
#       <EBox::LogObserver::tableInfo> + 'helper'
#       component which is the module that implements the LogObserver
#       interface
#
sub getTableInfo
{
    my ($self, $index) = @_;

    my $tables = $self->getAllTables();
    unless (exists $tables->{$index}) {
        $self->{tables} = undef; # Delete cache
        $tables = $self->getAllTables(); # Ask again
    }

    return $tables->{$index};
}



sub getModTableInfos
{
    my ($self, $mod) = @_;
    my @tableInfos;

    my $ti = $mod->tableInfo();
    if (ref $ti eq 'ARRAY') {
        @tableInfos = @{ $ti };
    }
    elsif (ref $ti eq 'HASH') {
        EBox::warn('tableInfo() in ' . $mod->name .
                   ' must return a reference to a list of hashes not the hash itself');
        @tableInfos = ( $ti );
    }
    else {
        throw EBox::Exceptions::Internal(
                                         $mod->name .
                                         "'s tableInfo returned invalid module"
                                        );
    }

    return \@tableInfos;
}

sub getLogDomains
{
    my ($self) = @_;

    my $tables = $self->getAllTables();
    my %logdomains = map { $_ => $tables->{$_}->{'name'} } keys %{$tables};
    return \%logdomains;
}



# keept for coapmibilty with old extended backups
sub extendedRestore
{
  my ($self, %params) = @_;
  my $dir    = $params{dir};

  my $dbengine = EBox::DBEngineFactory::DBEngine();
  my $dumpFileBasename = 'eboxlogs';

  $dbengine->restoreDB($dir, $dumpFileBasename);
}


sub backupDomains
{
    my $name = 'logs';
    my %attrs  = (
                  printableName => __('Logs'),
                  description   => __(q{Zentyal Server logs database}),
                 );

    return ($name, \%attrs);
}


sub dumpExtraBackupData
{
    my ($self, $dir, %backupDomains) = @_;

    if ($backupDomains{logs} ) {
        my $dbengine = EBox::DBEngineFactory::DBEngine();
        my $dumpFileBasename = "eboxlogs";

        $dbengine->backupDB($dir, $dumpFileBasename);
    }
}

sub _checkValidDate # (date)
{
    my ($datestr) = @_;


    my ($date, $time) = split (/ /, $datestr);
    my ($year, $month, $day) = split (/-/, $date);
    my ($hour, $min, $sec) = split (/:/, $time);

    unless (defined($year) and defined($month) and defined($day)) {
        return undef;
    }
    return undef unless ($year =~ /\d\d\d\d/ );
    return undef unless ($month =~ /\d+/ and $month < 13 and $month > 0);
    return undef unless ($day =~ /\d+/ and $day < 32 and $day > 0);
    return undef unless ($hour =~ /\d+/ and $hour < 24 and $hour > -1);
    return undef unless ($min =~ /\d+/ and $min < 60 and $min > -1);
    return undef unless ($sec =~ /\d+/ and $sec < 60 and $sec > -1);

    return 1;
}

# Method: search
#
#       Search for content in stored logs (in posgresql database)
#
# Parameters:
#
#       from - String which represents the "from" date in "year-month-day
#       hour:min:sec" format
#
#       to - String which represents the "to" date in "year-month-day
#       hour:min:sec" format
#
#       index - String the table's name
#
#       pagesize - Int the page's size to return the result
#
#       page - Int the page to search for results
#
#       filters - hash ref a list of filters indexed by name which
#       contains the value of the given filter (normally a
#       string). Passing *undef* no filters are applied
#
# Returns:
#
#       hash ref - containing the search result. The components are
#       the following:
#
#         totalret - Int the number of results, it could be zero
#         arrayret - array ref containing the each returned row. Each
#         component is an hash ref whose description is determined by
#         the returned value of <EBox::Logs::getTableInfo> with
#         parameter <EBox::Logs::search::index>.
#
sub search {
    my ($self, $from, $to, $index,
        $pagesize, $page, $timecol, $filters) = @_;

    my $dbengine = EBox::DBEngineFactory::DBEngine();

    my $tables = $self->getAllTables();
    my $tableinfo = $tables->{$index};
    my $table = $tableinfo->{'tablename'};

    unless (defined $tableinfo) {
        throw  EBox::Exceptions::External( __x(
                   'Table {table} does not exist', 'table' => $table));
    }

    $self->{'sqlselect'} = { };

    $self->_addTableName($table);
    if (_checkValidDate($from)) {
        $self->_addDateFilter($timecol, $from, '>');
    }
    if (_checkValidDate($to)) {
        $self->_addDateFilter($timecol, $to, '<');
    }
    if ($filters and %{$filters}) {
        foreach my $field (keys %{$filters}) {
            unless (exists $tableinfo->{'titles'}->{$field}) {
                           throw  EBox::Exceptions::Internal(
                           "Field $field does not appear in tableinfo's titles field");
                        }
            if ($field eq 'event') {
                $self->_addFilter($field, $filters->{$field});
            } else {
                $self->_addRegExp($field, $filters->{$field});
            }
        }
    }

    $self->_addSelect('COUNT(*)');
        my @count = @{$dbengine->query($self->_sqlStmnt())};
    my $tcount = $count[0]{'count'};

    # Do not go on if you don't have any result
    if ( $tcount == 0 ) {
        return { 'totalret' => $tcount,
                     'arrayret' => [],
               };
    }

    my $tpages = ceil($tcount / $pagesize) - 1;


    if ($page < 0) { $page = 0; }
    if ($page > $tpages) { $page = $tpages; }

    my $offset = $page * $pagesize;
    $self->_addPager($offset, $pagesize);
    $self->_addOrder("$timecol DESC");

    $self->_addSelect('*');


    my @ret = @{$dbengine->query($self->_sqlStmnt())};

        my $hashret = {
                       'totalret' => $tcount,
                       'arrayret' => \@ret
                      };


    return $hashret;
}


# Method: totalRecords
#
#       Get the total records stored in database for a given table
#
# Parameters:
#
#       tableName - String the table name to check the number of
#       records
#
# Returns:
#
#       Integer - the number of records for this table
#
sub totalRecords
{
    my ($self, $table) = @_;
    my $dbengine = EBox::DBEngineFactory::DBEngine();

    my $sql = "SELECT COUNT(*) FROM $table";
    my @tarray = @{$dbengine->query($sql)};
    my $tcount = $tarray[0]{'count'};

    return $tcount;
}

# Method: consolidatedLogForDay
#
# Parameters:
#     table - consolidated table. The suffix '_daily' is added automaticallu
#     date  - date in format yyyy-mm-dd
#
#  Returns:
#      array reference. Each row will be a hash reference with
#      column/values as key/values. Remember that it will be always a 'date'
#      field.
#      If there is not data it will return a empty array
sub consolidatedLogForDay
{
    my ($self, $table, $date) = @_;
    $date or
        throw EBox::Exceptions::MissingArgument('date');
    $table or
        throw EBox::Exceptions::MissingArgument('table');

    # put the standard 00:00:00  hour
    ($date) = split '\s', $date;
    $date .= ' 00:00:00';


    $table = $table . '_daily';

    my $dbengine = EBox::DBEngineFactory::DBEngine();

    my $sql = "SELECT * FROM $table WHERE date='$date'";

    my @results = @{  $dbengine->query($sql) };
    return \@results;
}

# Method: yesterdayDate
#
#  Returns:
#    the yesterday date in string format so it can used in SQL queries and
#    i nthe consolidatedLogForDay method
sub yesterdayDate
{
    my ($self) = @_;
    my $yesterdayTs = time()  - 86400; # 86400 seconds in a day
    my  ($sec,$min,$hour,$mday,$mon,$year) = localtime($yesterdayTs);
    $year += 1900;
    $mon  +=1;

    return "$year-$mon-$mday 00:00:00";
}



sub _addRegExp
{
    my ($self, $field, $regexp) = @_;
    return unless (defined($field) and defined($regexp)
                   and length($regexp) > 0);
    $self->{'sqlselect'}->{'regexp'}->{$field} = $regexp;
}

sub _addFilter
{
    my ($self, $field, $filter) = @_;
    return unless (defined($field) and defined($filter)
                   and length($filter) > 0);
    $self->{'sqlselect'}->{'filter'}->{$field} = $filter;
}

sub _addDateFilter
{
    my ($self, $field, $date, $operator) = @_;
    return unless (defined($date) and defined($operator));
    $self->{'sqlselect'}->{'date'}->{$operator}->{'date'} = $date;
    $self->{'sqlselect'}->{'date'}->{$operator}->{'field'} = $field;
}

sub _addPager
{
    my ($self, $offset, $limit) = @_;
    $self->{'sqlselect'}->{'offset'} = $offset;
    $self->{'sqlselect'}->{'limit'} = $limit;
}


sub _addOrder
{
    my ($self, $order) = @_;

    $self->{sqlselect}->{order} = $order;
}

sub _addTableName
{
    my ($self, $table) = @_;
    $self->{'sqlselect'}->{'table'} = $table;
}

sub _addSelect
{
    my ($self, $select) = @_;
    $self->{'sqlselect'}->{'select'} = $select;
}

sub _sqlStmnt {
    my ($self) = @_;

    my @params;
    my $sql = $self->{'sqlselect'};
    my $stmt = "SELECT $sql->{'select'} FROM  $sql->{'table'} ";

    if ($sql->{'regexp'} or $sql->{'date'}) {
        $stmt .= 'WHERE ';
    }

    my $and = '';
    if ($sql->{'date'}) {
        foreach my $op (keys %{$sql->{'date'}}) {
            $stmt .= "$and $sql->{'date'}->{$op}->{'field'} $op ? ";
                        $and = 'AND';
            push @params, $sql->{'date'}->{$op}->{'date'};
        }
    }

    if ($sql->{'regexp'}) {
        foreach my $field (keys %{$sql->{'regexp'}}) {
            $stmt .= "$and CAST($field as text) ~ ? ";
            $and = 'AND';
            push @params, $sql->{'regexp'}->{$field};
        }
    }
    if ($sql->{'filter'}) {
        foreach my $field (keys %{$sql->{'filter'}}) {
            $stmt .= "$and $field = ? ";
            $and = 'AND';
            push @params, $sql->{'filter'}->{$field};
        }
    }

    if ($sql->{order}) {
        $stmt .= 'ORDER BY ' . $sql->{order} . ' ';
    }

    $stmt .= "OFFSET ? LIMIT ?";
    push @params, $sql->{'offset'}, $sql->{'limit'};

    return $stmt, @params;
}

# Implement GConfModule interface

# Method: menu
#
#       Overrides EBox::Module method.
#
#
sub menu
{
    my ($self, $root) = @_;
    my $folder = new EBox::Menu::Folder('name' => 'Logs',
                                        'text' => $self->printableName(),
                                        'separator' => 'Core',
                                        'order' => 80);

    $folder->add(new EBox::Menu::Item('url' => 'Logs/View/SelectLog',
                                      'text' => __('Query Logs')));

    $folder->add(new EBox::Menu::Item('url' =>'Logs/Composite/ConfigureLog',
                                      'text' => __('Configure Logs')));


    $root->add($folder);
}


# Implement LogObserver interface

sub tableInfo
{
    my ($self) = @_;

    my $titles = { 'timestamp' => __('Date'),
                   'clientaddress' => __('Client Address'),
                   'module' => __('Module'),
                   'action' => __('Action'),
                   'params' => __('Params'),
                   'committed' => __('Committed')
                 };
    my @order = ('timestamp', 'source', 'module',
                 'action', 'params', 'committed');
    return {
            'name' => __('Admin'),
            'index' => 'admin',
            'titles' => $titles,
            'order' => \@order,
            'tablename' => 'admin',
            'filter' => ['source', 'module']
           };
}

# Helper functions

# Method: _saveEnabledLogs
#
#       (Private)
#
#       This function saves the enabled logs in a file.
#       We have to do this beacuse the logger daemon will request this
#       configuration as root user.
#
#       Another approach could be creating a separated script to
#       query ebox conf.
#
sub _saveEnabledLogsModules
{
    my ($self) = @_;

    my $enabledLogs = $self->model('ConfigureLogTable')->enabledLogs();

    unless (-d ENABLED_LOG_CONF_DIR) {
        mkdir (ENABLED_LOG_CONF_DIR);
    }

    # Create a string of domains separated by comas
    my $enabledLogsString = join (',', keys %{$enabledLogs});

    my $file;
    unless (open($file, '>' . ENABLED_LOG_CONF_FILE)) {
        throw EBox::Exceptions::Internal(
                'Cannot open ' . ENABLED_LOG_CONF_FILE);
    }

    print $file "$enabledLogsString";
    close($file);
}

# Method: _restoreEnabledLogsModules
#
#       (Private)
#
#       This function restores the enabled logs saved in a file by
#       <EBox::Logs::_saveEnabledLogsModules>
#       We have to do this beacuse the logger daemon will request this
#       configuration as root user.
#
#       Anotther approach could be creating a separated script to
#       query ebox conf.
#
# Returns:
#
#       undef  - if there's no enabled logs stored yet
#       hash ref containing the enabled logs
sub _restoreEnabledLogsModules
{
    my ($self) = @_;

    my $file;
    unless (open($file, ENABLED_LOG_CONF_FILE)) {
        return undef;
    }

    my $string = <$file>;
    close($file);
    return undef unless (defined($string));

    my %enabled;
    foreach my $domain (split(/,/, $string)) {
        $enabled{$domain} = 1;
    }

    return \%enabled;
}


# Overrides:
#  EBox::Report::DiskUsageProivider::_facilitiesForDiskUsage
#
# Warning:
#   this implies thhat all postgresql data are log, if someday other kind of
#   data is added to the database we will to change this (and maybe overriding
#   EBox::Report::DiskUsageProivider::diskUsage will be needed)
sub _facilitiesForDiskUsage
{
  my ($self) = @_;

  my $printableName = __('Log messages');

  return {
          $printableName => [ PG_DATA_DIR ],
         };
}

# Method: forcePurge
#
#      Force to purge every table used to log data in eBox given a
#      timestamp
#
# Parameters:
#
#      lifetime - Int the allowed data not to purge should be
#                 timestamped before this limit which is set in hours
#
# Exceptions:
#
#      <EBox::Exceptions::External> - thrown if the lifetime is not a
#      positive number
#
sub forcePurge
{
  my ($self, $lifetime) = @_;
  ($lifetime > 0) or
    throw EBox::Exceptions::External(
                     __("Lifetime parameter must be a positive number of hours")
                                    );

  my $now           = time();
  my $thresholdDate = $self->_thresholdDate($lifetime, $now);

  my @tables = map {
      @{  $self->getModTableInfos($_) }
  } @{ $self->getLogsModules };

  foreach my $tableInfo ( @tables ) {
    my $table = $tableInfo->{tablename};
    my $timeCol = 'timestamp';
    $self->_purgeTable($table, $timeCol, $thresholdDate);
  }
}

# Method: purge
#
#      Purge every table used to log data in eBox with the threshold
#      lifetime defined by 'lifetime' field in
#      <EBox::Logs::Model::ConfigureLogDataTable> model
#
#     This method is called by a cron job.
#
# Exceptions:
#
#      <EBox::Exceptions::External> - thrown if the lifetime is not a
#      positive number
#
sub purge
{
  my ($self) = @_;

  my $now = time();
  my %thresholdByModule = ();

  # get the threshold date for each domain

  foreach my $id ( @{ $self->model('ConfigureLogTable')->ids() } ) {
    my $row_r = $self->model('ConfigureLogTable')->row($id);
    my $lifeTime = $row_r->valueByName('lifeTime');

    # if lifeTime == 0, it should never expire
    $lifeTime or
      next;

    my $threshold = $self->_thresholdDate($lifeTime, $now);
    $thresholdByModule{$row_r->valueByName('domain')} = $threshold;
  }

  # purge each module


  while (my ($modName, $threshold) = each %thresholdByModule) {
      my $mod = EBox::Global->modInstance($modName);
      my @logTables = @{ $self->getModTableInfos($mod) };

      foreach my $table (@logTables) {
          my $dbTable = $table->{tablename};
          my $timeCol = 'timestamp';

          $self->_purgeTable($dbTable, $timeCol, $threshold);
      }


  }
}


# Transform an hour into a localtime
sub _thresholdDate
{
  my ($self, $lifeTime, $now) = @_;

  # lifeTime must be in hours
  my $lifeTimeSeconds = $lifeTime * 3600;
  my $threshold = $now - $lifeTimeSeconds;
  return scalar localtime($threshold);
}

# Do perform the purge in a table
sub _purgeTable
{
  my ($self, $table, $timeCol, $thresholdDate) = @_;

  my $finalThreshold;
  my $dbengine = EBox::DBEngineFactory::DBEngine();

  if (EBox::Logs::SlicedBackup::slicedMode()) {
      $finalThreshold = EBox::Logs::SlicedBackup::limitPurgeThreshold(
                                                                      $dbengine,
                                                                      $table,
                                                                      $thresholdDate,

                                                                     );
      if (not defined $finalThreshold) {
          EBox::info("Cannot purge logs of table $table before $thresholdDate because they are unarchived backup slices");
          return;
      } elsif ($thresholdDate ne $finalThreshold) {
          EBox::info("Log purge of table before $thresholdDate has be restricted to records before $finalThreshold because it were not archived backup slices");
      }

  } else {
      $finalThreshold = $thresholdDate;
  }

  my $sqlStatement = "DELETE FROM $table WHERE $timeCol < '$finalThreshold'";
  $dbengine->query($sqlStatement);
}

sub archiveBackupSlices
{
    my ($self, $force) = @_;

    if (not $force) {
        my $enabled = EBox::Logs::SlicedBackup::slicedMode();
        $enabled or
            return;
    }

    my $dbengine = EBox::DBEngineFactory::DBEngine();
    EBox::Logs::SlicedBackup::archive($dbengine);
}

1;
