/*
	AUTHOR:		Erik Mostert
	PURPOSE:	To find SQL objects where the supplied name forms part of the object name or definition
*/

declare @name	varchar(255) = 'RejectionEmailSettings'

-- CHECK CONSTRAINTS
select 'CHECK CONSTRAINT'
     , name 
  from sys.check_constraints
 where name like '%'+ @name +'%'

-- STORED PROCS
select 'STORED PROC'
     , * 
  from sys.procedures prc
  join sys.sql_modules mdl on mdl.object_id = prc.object_id
 where prc.name like '%'+ @name +'%'
    or mdl.definition like '%'+ @name +'%'

-- DEFAULT CONSTRAINTS
select 'DEFAULT CONSTRAINT'
     , * 
  from sys.default_constraints
 where name like '%'+ @name +'%'

-- KEY CONSTRAINTS
select 'PRIMARY KEY CONSTRAINT'
     , * 
  from sys.key_constraints
 where name like '%'+ @name +'%'

-- FOREIGN KEYS
select 'FOREIGN KEY CONSTRAINT'
     , * 
  from sys.foreign_keys
 where name like '%'+ @name +'%'

SELECT 'TABLE'
     , * 
  FROM sys.tables tbl
  JOIN sys.schemas scm ON scm.schema_id = tbl.schema_id
 WHERE tbl.name = @name
AND scm.name = 'HRM'


