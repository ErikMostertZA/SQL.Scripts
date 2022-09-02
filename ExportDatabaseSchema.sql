-- This script will extract the entire database schema from a source database and compile the creation scripts into a single file
-- The script was designed to be executed from SQLCMD for automation and needs to be tested using SQLCMD
-- When modifying and testing the script, you can use the following powershell command

-- sqlcmd -S "<Source Server>" -d "<Source Database>" -U "<Source User>" -b -P "<Source Password>" -v outputLocation = "<Output Path>" destinationDatabase = "<DB to Create>" -i "<FilePath to script>ExportDatabaseSchema.sql"


/*
  SET THE ADVANCED OPTIONS TO WRITE THE OUTPUT TO A TEXT FILE
*/
sp_configure 'show advanced options', 1;
go
reconfigure;
go
sp_configure 'Ole Automation Procedures', 1;
go
reconfigure;
go


/*
  DECLARE SOME OF THE INITIAL VARIABLES
*/
declare @hresult int
declare @win int;

declare @sourceDatabase varchar(255) = (select DB_NAME())
declare @destinationDatabase varchar(255) = '$(destinationDatabase)'
declare @sourceSql varchar(255) = N'use ' + @sourceDatabase
declare @keepCDC bit = (select is_cdc_enabled from sys.databases where name = @sourceDatabase)

execute(@sourceSql)

declare @fileName varchar(255)
set @fileName = '$(outputLocation)\$(destinationDatabase).sql'

declare @OLE int
declare @FileID int

begin try

  execute sp_OACreate 'Scripting.FileSystemObject', @OLE out
  IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win
  
  execute sp_OAMethod @OLE, 'OpenTextFile', @FileID out, @fileName, 2, 1
  IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

  /* CREATE THE SCRIPT TO DROP AND CREATE THE DESTINATION DATABASE IF NEEDED
     AND SWITCH THE CONTEXT TO THE NEW DB */
  declare @createDbSQL nvarchar(max);
  
  set @createDbSQL = 
  '
  -- Switch to Master so we can create/re-create the database
  use master
  go
  
  declare @SQL nvarchar(1000);
  
  -- Drop database if needed
  if exists (select 1 from sys.databases where [name] = N'''+ @destinationDatabase +''')
  begin
    set @SQL = N''use ['+ @destinationDatabase +'];
                  alter database '+ @destinationDatabase +' set single_user with rollback immediate;
                  
                  use [master];
                  drop database '+ @destinationDatabase +';'';
    
    exec (@SQL);
  end;
  go
  
  -- Create database
  create database '+ @destinationDatabase +'
  go
  
  -- Switch session to new database
  USE '+ @destinationDatabase +'  
  GO  
  
  ' + case when @keepCDC = 1 
           then '
  -- CDC was enabled on source database, so we enable it here
  EXEC sys.sp_cdc_enable_db  
  GO 
  '
           else ''
       end +'
   ';
  
  execute sp_OAMethod @FileID, 'WriteLine', Null,@createDbSQL
  IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

  /* CREATE THE USER DEFINED TYPE SCRIPTS, IF ANY */
  if exists (select top 1 1
              from sys.types
             where is_user_defined = 1)
  begin
    
    execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create any user-defined types from source database'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    -- The table to hold our list of types
    declare @userTypeTable table
    (
      typeName  varchar(255),
      dataType  varchar(255),
      precision int,
      scale     int,
      length    int,
      nullable  bit,
      processed bit
    )
    
    insert into @userTypeTable
    select t1.name
         , t2.name
         , t1.precision
         , t1.scale
         , t1.max_length
         , t1.is_nullable
         , 0
      from sys.types t1
      join sys.types t2 on t2.system_type_id = t1.system_type_id and t2.is_user_defined = 0
     where t1.is_user_defined = 1 and t2.name <> 'sysname'  
     order by t1.name
    
    declare @currentType      varchar(255)
    declare @currentDataType  varchar(255)
    declare @precision        int
    declare @scale            int
    declare @length           int
    declare @isNullable       bit
    declare @customTypeSql    nvarchar(max)
    
    while exists (select top 1 1 
                    from @userTypeTable
                   where processed = 0)
    begin
    
      select top 1
             @currentType = typeName
           , @currentDataType = dataType
           , @precision = precision
           , @scale = scale
           , @length = length
           , @isNullable = nullable
        from @userTypeTable
        where processed = 0
    
      select @customTypeSql = N'
  if not exists (select name from systypes where name = '''+ @currentType +''') 
  begin
    exec sp_addtype '+ @currentType +', '''+ @currentDataType + 
        case when @currentDataType in ('varchar','varchar','char','nchar') 
             then '('+ CAST(@length as varchar) +')' 
             when @currentDataType = 'decimal'
             then '(' + CAST(@precision as varchar) + ', ' + CAST(@scale as varchar) + ')'
             else '' 
        end + '''' + 
        case when @isNullable = 1 
             then ', ''NULL' 
             else ', ''NOT NULL' 
        end +'''
  end 
  '
    
      execute sp_OAMethod @FileID, 'WriteLine', Null, @customTypeSql
      IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

      update @userTypeTable
         set processed = 1
       where typeName = @currentType
    end
  
  end
  
  /* CREATE USER DEFINES TABLE TYPE SCRIPTS, IF ANY */
  if exists (select top 1 1
               from sys.table_types
              where is_user_defined = 1)
  begin
    
    execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create any user-defined table types from source database'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    declare @tableTypes table
    (
      tableName varchar(255),
      processed bit
    )
    
    insert into @tableTypes
    select tt.name,  0 from sys.table_types tt
    where tt.is_user_defined = 1
    
    declare @tableTypeName varchar(255)
    declare @maxColNumber int
    declare @userTypeSQL nvarchar(max)
    
    while exists (select top 1 1 
                    from @tableTypes
                   where processed = 0)
    begin
    
      select top 1 
             @tableTypeName = tableName
        from @tableTypes
       where processed = 0
    
       select @maxColNumber = max(column_id)
         from sys.table_types tt
         join sys.columns col on col.object_id = tt.type_table_object_id
         join sys.types st on st.user_type_id = col.system_type_id
        where tt.name = @tableTypeName
    
       select @userTypeSQL = N'CREATE TYPE [dbo].['+ @tableTypeName + '] as TABLE
  (' + char(13)
       
       select @userTypeSQL = @userTypeSQL + N'  ['+ col.Name +'] [' + st.name +'] ' + 
         case when st.name in ('varchar','nvarchar','char','nchar') 
              then '('+ CAST(st.max_length as varchar) +')' 
              when st.name = 'decimal'
              then '(' + CAST(st.precision as varchar) + ', ' + CAST(st.scale as varchar) + ')'
              else '' 
          end +  
         case when col.is_nullable = 1 
              then ' NULL' 
              else ' NOT NULL' 
          end + 
         case when col.column_id = @maxColNumber
              then '' + char(13)
              else ',' + char(13)
          end 
         from sys.table_types tt
         join sys.columns col on col.object_id = tt.type_table_object_id
         join sys.types st on st.user_type_id = col.system_type_id
        where tt.name = @tableTypeName
        order by col.column_id
    
       select @userTypeSQL = @userTypeSQL + N'
  )
  go
  '
    
      update @tableTypes
      set processed = 1
      where tableName = @tableTypeName
      
      execute sp_OAMethod @FileID, 'WriteLine', Null,@userTypeSQL
    end
  end
  
  /* CREATE TABLE SCRIPTS, IF ANY */
  if exists (select top 1 1
               from sys.tables
              where is_ms_shipped = 0)
  begin 
  
    execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create tables'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    declare @tableList table
    (
      tableName       varchar(255),
      processed       bit
    )
    
    insert into @tableList
    select  [name], 0  
      from sys.tables 
     where is_ms_shipped = 0
    
    declare @tableSQL     nvarchar(max)
    declare @tableName    varchar(max)
   
    while exists (select top 1 1 
                    from @tableList
                   where processed = 0)
    begin
  
      select top 1 
             @tableName = tableName
        from @tableList
       where processed = 0
      
      select @tableSQL = 'CREATE TABLE [' + @tableName + ']' + char(10) + '(' + char(10)
  
      select @tableSQL = @tableSQL + ' [' + sc.Name + '] ' + st.Name +
        case when st.name in ('varchar','nvarchar','char','nchar') 
             then '(' + case when cast(sc.Length as varchar) = -1 
                             then 'max' 
                             else cast(sc.Length as varchar) 
                         end + ') ' 
                             
              when st.name = 'decimal'
              then '(' + cast(sc.prec as varchar) + ', ' + CAST(sc.scale as varchar) + ')'
              when st.name in ('binary', 'varbinary')
              then '(' + case when cast(sc.length as varchar) = -1
                              then 'max'
                              else cast(sc.length as varchar)
                          end + ')'
              else ' ' 
         end +
        case when sc.IsNullable = 1 
             then ' NULL' 
             else ' NOT NULL' 
         end + 
        case when (select col_name(object_id(@tableName), column_id) from sys.identity_columns where object_id = object_id(@tableName)) = sc.name
             then ' identity(' + cast(ident_seed(@tableName) as varchar) + ', ' + cast(ident_incr(@tableName) as varchar) + ')'
             else ' ' 
         end + ',' + char(10)
        from sysobjects so
        join syscolumns sc on sc.id = so.id
        join systypes st on st.xusertype = sc.xusertype
       where so.name = @tableName
       order by sc.ColID
  
      select @tableSQL = @tableSQL + ');' + CHAR(13) + CHAR(13)
  
     execute sp_OAMethod @FileID, 'WriteLine', Null, @tableSQL
     IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

      update @tableList
         set processed = 1
       where tableName = @tableName
    end
  end
  
  /* CREATE CDC TABLE SCRIPTS, IF ANY */
  if exists (select top 1 1
               from sys.tables st
               join sys.schemas ss on ss.schema_id = st.schema_id
              where ss.name = 'cdc'
                and st.name like 'dbo_%')
  begin
  
    execute sp_OAMethod @FileID, 'WriteLine', Null, '
  -- Create CDC tables
  -- NOTE: These are created in a CDC schema that is part of the user tables, not system tables.  It should be OK for unit testing though'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    declare @cdcTableList table
    (
      tableName       varchar(255),
      processed       bit
    )
    
    insert into @cdcTableList
    select  st.[name], 0  
      from sys.tables st
      join sys.schemas ss on ss.schema_id = st.schema_id
     where ss.name = 'cdc'
       and st.name like 'dbo_%'
    
    declare @cdcTableName   varchar(max);
    declare @cdcSql         varchar(max);
    
    while exists (select top 1 1 
                    from @cdcTableList
                   where processed = 0)
    begin
      select top 1 
             @cdcTableName = tableName
        from @cdcTableList
       where processed = 0
      
      select @cdcSql = ' 
  CREATE TABLE [cdc].[' + @cdcTableName + ']' + char(10) + '(' + char(10)
    
      select @cdcSQL = @cdcSQL + ' [' + sc.Name + '] ' + st.Name +
        case when st.name in ('varchar','nvarchar','char','nchar') 
             then '(' + case when cast(sc.Length as varchar) = -1 
                             then 'max' 
                             else cast(sc.Length as varchar) 
                         end + ') ' 
                             
             when st.name = 'decimal'
             then '(' + CAST(sc.prec as varchar) + ', ' + CAST(sc.scale as varchar) + ')'
             when st.name in ('binary', 'varbinary')
             then '(' + CAST(sc.length as varchar) + ')' 
             else ' ' 
         end +
        case when sc.IsNullable = 1 
             then ' NULL' 
             else ' NOT NULL' 
         end + 
        case when (select col_name(object_id('cdc.' + @cdcTableName), column_id) from sys.identity_columns where object_id = object_id('cdc.'+@cdcTableName)) = sc.name
             then ' identity(' + CAST(ident_seed('cdc.' + @cdcTableName) as varchar) + ', ' + CAST(ident_incr('cdc.' + @cdcTableName) as varchar) + ')'
             else ' ' 
        end + ',' + char(10)
       from sysobjects so
       join syscolumns sc on sc.id = so.id
       join systypes st on st.xusertype = sc.xusertype
      where so.name = @cdcTableName
      order by sc.ColID
    
     select @cdcSQL = @cdcSQL + ');' + CHAR(13) + CHAR(13)
    
       update @cdcTableList
         set processed = 1
       where tableName = @cdcTableName
    
      execute sp_OAMethod @FileID, 'WriteLine', Null, @cdcSql
      IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    end
  end
  
  /* CREATE THE STORED PROC SCRIPTS, IF ANY */
  if exists (select top 1 1
               from sys.objects ob
               join sys.sql_modules mo on mo.object_id = ob.object_id
              where type = 'P'
                and is_ms_shipped = 0
                and name not in ('rss_dbreindex_1'))
  begin 
  
    execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create stored procedure from definitions in source database'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win
  
    declare @storedProcTable table
    (
      procName  varchar(max),
      procDef   varchar(max),
      processed bit
    )
    
    insert into @storedProcTable
    select name, mo.definition, 0 
      from sys.objects ob
      join sys.sql_modules mo on mo.object_id = ob.object_id
     where type = 'P'
       and is_ms_shipped = 0
       and name not in ('rss_dbreindex_1')
    
    declare @procName nvarchar(max)
    declare @procSql nvarchar(max)
    declare @procDef nvarchar(max)
    
    while exists (select top 1 1 
                    from @storedProcTable
                   where processed = 0)
    begin
    
      select top 1 
             @procName = procName
           , @procDef = procDef
        from @storedProcTable
       where processed = 0
    
      select @procSql = N'
  
  if object_id('''+ @procName +''') is not null
    drop procedure '+ @procName +'
  go
        '
    
       select @procSql = @procSql + @procDef + N'
  go
  
  grant execute on ' + @procName + ' to public
  go
       '
       execute sp_OAMethod @FileID, 'WriteLine', Null, @procSql
       IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win
    
       update @storedProcTable
       set processed = 1
       where procName = @procName
    end
  end

  /* CREATE DEFAULT CONSTRAINTS WHERE NEEDED */
  if exists (select top 1 1
               from sys.columns col 
               join sys.default_constraints con on con.object_id = col.default_object_id 
              where con.is_ms_shipped = 0)
 begin

 execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create default constraints where needed'
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

  declare @constraintTable table
  (
    constraintId    int,
    tableName       varchar(255),
    constName       varchar(255),
    constDefinition varchar(255),
    columnName      varchar(255),
    processed       bit
  )

  insert into @constraintTable
  select con.object_id, tbl.name, con.name, con.definition, col.name, 0
    from sys.columns col
  join sys.tables tbl on tbl.object_id = col.object_id
  join sys.default_constraints con on con.object_id = col.default_object_id 
  where con.is_ms_shipped = 0

  declare @constraintSql nvarchar(max) = ''
  declare @constraintId int

  while exists (select top 1 1 
                  from @constraintTable
                 where processed = 0)
  begin 
  select top 1 @constraintId = constraintId
    from @constraintTable
    where processed = 0

    select top 1 @constraintSql =  N'
  alter table ' + tableName + '
  add constraint ' + constName + '
  default ' + constDefinition + '
  for ' + columnName + char(13)
      from @constraintTable
     where constraintId = @constraintId

    execute sp_OAMethod @FileID, 'WriteLine', Null, @constraintSql
    IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win

    update @constraintTable
    set processed = 1
    where constraintId = @constraintId

  end
  
  set @constraintSql = 'GO' + char(13)
  execute sp_OAMethod @FileID, 'WriteLine', Null, @constraintSql
 end

  /* CREATE USER DEFINED FUNCTIONS AND VIEWS, IF ANY  */
  if exists (select top 1 1 
               from sys.sql_modules sm
               join sys.objects ob on ob.object_id = sm.object_id
               join sys.schemas sc on sc.schema_id = ob.schema_id
              where ob.type != 'P'
                and sc.name = 'dbo')
   begin 
    
      execute sp_OAMethod @FileID, 'WriteLine', Null, '-- Create user-defined functions and views'

      declare @definitionTable table
      (
        id          int identity(1, 1),
        name        varchar(255),
        definition  nvarchar(max),
        processed   int
      )

      insert into @definitionTable
      select ob.name, sm.definition, 0
        from sys.sql_modules sm
        join sys.objects ob on ob.object_id = sm.object_id
        join sys.schemas sc on sc.schema_id = ob.schema_id
       where ob.type != 'P'
         and sc.name = 'dbo'
       order by ob.type

      declare @functionId int
      declare @functionSQL  nvarchar(max)



      while exists (select top 1 1
                      from @definitionTable
                     where processed = 0)
      begin
        select top 1 
               @functionId = id
             , @functionSQL = definition + N'
             GO
             '
          from @definitionTable
         where processed = 0
         order by id
         

        execute sp_OAMethod @FileID, 'WriteLine', Null, @functionSQL

        update @definitionTable
        set processed = 1
        where id = @functionId
      end
   end

end try
begin catch
  EXEC @hresult=sp_OADestroy @win 
  IF @hresult <> 0 EXEC sp_OAGetErrorInfo @win;
  throw;
end catch 

  /* CLOSE THE HANDLES ON THE FILES AND REVERT THE CONFIG CHANGES */
  execute sp_OADestroy @FileID
  execute sp_OADestroy @OLE
  go
  
  sp_configure 'show advanced options', 1;
  go
  reconfigure;
  go
  sp_configure 'Ole Automation Procedures', 0;
  go
  reconfigure;
  go
