-- PURPOSE:		To remove all records from an existing database.  Usefull when running unit tests
-- AUTHOR:		Erik Mostert
-- DATE:		15-08-2022

-- NOTES:
/*
	This script removes all referential constraints, truncates all tables (excluding the list of ignored tables)
	Once truncated the referentail constriants are added back for each table.
	CDC is also disabled & enabled if needed
*/

-- Create a list of tables that should not be cleared
declare @tablesToIgnore table ( tableName varchar(255) )

insert into @tablesToIgnore
values
('accountstatustype'),
('accounttranscode')

-- Create a list of all tables to be cleared
declare @allTables table
(
  tableName   varchar(255),
  cdcEnabled  bit,
  processed   bit
)

insert into @allTables
select [name], [is_tracked_by_cdc], 0  
  from sys.tables 
 where is_ms_shipped = 0
   and [name] not in (select tableName 
                        from @tablesToIgnore)

-- Get the current constraints and store the restore script
declare @constraintRestore table
(
  id          int identity(1, 1),
  queryString varchar(max),
  processed   bit
)

insert into @constraintrestore
select N'alter table ' + quotename(object_schema_name(fk.parent_object_id)) + '.' + quotename(object_name(fk.parent_object_id)) 
       + ' add constraint ' + fk.name + ' foreign key (' + stuff((select ',' + c.name
                                                                    from sys.columns as c
                                                                   inner join sys.foreign_key_columns as fkc
                                                                      on fkc.parent_column_id = c.column_id
                                                                     and fkc.parent_object_id = c.[object_id]
                                                                   where fkc.constraint_object_id = fk.[object_id]
                                                                   order by fkc.constraint_column_id
                                                                     for xml path(''), type).value(N'./text()[1]', 'nvarchar(max)'), 1, 1, N'')
                                                    + ') references ' + quotename(object_schema_name(fk.referenced_object_id)) + '.' + quotename(object_name(fk.referenced_object_id))
                                                    + '(' + stuff((select ',' + c.name
                                                                     from sys.columns as c 
                                                                    inner join sys.foreign_key_columns as fkc 
                                                                       on fkc.referenced_column_id = c.column_id
                                                                      and fkc.referenced_object_id = c.[object_id]
                                                                    where fkc.constraint_object_id = fk.[object_id]
                                                                    order by fkc.constraint_column_id 
                                                                      for xml path(''), type).value(N'./text()[1]', N'nvarchar(max)'), 1, 1, N'') + ');', 0 
 from sys.foreign_keys as fk
where objectproperty(parent_object_id, 'ismsshipped') = 0; 

-- drop the existing constraints
declare @sql nvarchar(max);
set @sql = N'';

select @sql = @sql + N'alter table ' + quotename(object_schema_name(parent_object_id)) + '.' + quotename(object_name(parent_object_id)) + 
                      ' drop constraint ' + quotename(name) + ';'
from sys.foreign_keys;

exec sys.sp_executesql @sql;

-- truncate the tables
declare @tableName    varchar(255)
declare @truncateSql  varchar(255)
declare @alterCdcSql  varchar(512)
declare @addCdcSql    varchar(512)
declare @cdcEnabled   bit
declare @cdcInstance  varchar(255)
declare @cdcTableName varchar(255)

select * from @allTables

while exists (select top 1 1 
                from @allTables
               where processed = 0)
begin
  begin transaction

  select top 1 
         @tableName = tableName
       , @cdcEnabled = cdcEnabled
       , @cdcInstance = concat('dbo_', tableName)
       , @cdcTableName = concat('cdc.dbo_', @tableName, '_ct') 
  from @allTables where processed = 0

  -- Remove CDC if enabled
  if @cdcEnabled = 1
  begin
    if exists (select 1
                 from sys.tables
                where name = @tableName
                  and type_desc = 'USER_TABLE'
                  and is_tracked_by_cdc = 1)
    begin
      EXEC sys.sp_cdc_disable_table 'dbo',  @tableName , @cdcInstance;
    end
  end

  -- Truncate the table
  set @truncateSql = N'truncate table ['+ @tableName +']'
  exec (@truncateSql)

  -- Add CDC if enabled
  if @cdcEnabled = 1
  begin
    exec sys.sp_cdc_enable_table @source_schema = 'dbo', 
                                 @source_name = @tableName, 
                                 @role_name = 'cdc_admin', 
                                 @capture_instance = @cdcInstance

    set @alterCdcSql = 'if not exists (select 1 
                                         from sys.columns 
                                        where name in  (''__id'', ''__processedon'') 
                                          and object_id = object_id(''' + @cdcTableName + ''') )
                        begin
                          alter table ' + @cdcTableName + ' 
                          add   [__id] int identity(1,1),
                                [__processedon] datetime null
                        end'

    execute (@alterCdcSql)
  end

  update @allTables
     set processed = 1
   where tableName = @tableName
     and processed = 0

  if(@@ERROR != 0)
  begin 
    print 'An error occurred while truncating table "' + @tableName + '"'
    rollback transaction
    return
  end

  commit transaction
end

-- Restore constraints
--declare @restoreSql varchar(max)
--declare @id         int
--while exists (select top 1 1
--                from @constraintRestore
--               where processed = 0)
--begin
--begin transaction
--  select top 1
--         @id = id
--       , @restoreSql = queryString
--    from @constraintRestore
--   where processed = 0

--   exec (@restoreSql)

--   update @constraintRestore
--   set processed = 1
--   where id = @id

--   if(@@ERROR != 0)
--  begin 
--    print 'An error occurred while restoring constraint on table'
--    print @restoreSql
--    rollback transaction
--    return
--  end

--  commit transaction
--end

