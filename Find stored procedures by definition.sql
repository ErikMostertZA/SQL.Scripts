select top 10 * 
from sys.procedures prc
join sys.sql_modules mdl on mdl.object_id = prc.object_id
where mdl.definition like '%HRM.Employee %'