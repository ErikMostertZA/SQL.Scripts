/***********************************************/
/* Server Side Trace                           */
/***********************************************/
-- Declare variables
DECLARE @rc INT
DECLARE @TraceID INT
DECLARE @maxFileSize bigint
DECLARE @fileName NVARCHAR(128)
DECLARE @on bit
DECLARE @dbId int = (select DB_ID('DeadlockDb'))

-- Set values
SET @maxFileSize = 5
SET @fileName = N'C:\Users\erikmo\Documents\RR Documentation\'
SET @on = 1

-- Create trace
EXEC @rc = sp_trace_create @TraceID output, 0, @fileName, @maxFileSize, NULL 

-- If error end process
IF (@rc != 0) GOTO error

-- Set the events and data to collect
EXEC sp_trace_setevent @TraceID, 13,  1, @on
EXEC sp_trace_setevent @TraceID, 13, 12, @on
EXEC sp_trace_setevent @TraceID, 13, 13, @on
EXEC sp_trace_setevent @TraceID, 13, 14, @on
EXEC sp_trace_setevent @TraceID, 13, 15, @on
EXEC sp_trace_setevent @TraceID, 13, 16, @on
EXEC sp_trace_setevent @TraceID, 13, 17, @on
EXEC sp_trace_setevent @TraceID, 13, 22, @on

EXEC sp_trace_setevent @TraceID, 25,  1, @on
EXEC sp_trace_setevent @TraceID, 25, 12, @on
EXEC sp_trace_setevent @TraceID, 25, 13, @on
EXEC sp_trace_setevent @TraceID, 25, 14, @on
EXEC sp_trace_setevent @TraceID, 25, 15, @on
EXEC sp_trace_setevent @TraceID, 25, 16, @on
EXEC sp_trace_setevent @TraceID, 25, 17, @on
EXEC sp_trace_setevent @TraceID, 25, 22, @on

EXEC sp_trace_setevent @TraceID, 59,  1, @on
EXEC sp_trace_setevent @TraceID, 59, 12, @on
EXEC sp_trace_setevent @TraceID, 59, 13, @on
EXEC sp_trace_setevent @TraceID, 59, 14, @on
EXEC sp_trace_setevent @TraceID, 59, 15, @on
EXEC sp_trace_setevent @TraceID, 59, 16, @on
EXEC sp_trace_setevent @TraceID, 59, 17, @on
EXEC sp_trace_setevent @TraceID, 59, 22, @on

-- Set Filters
-- filter1 include databaseId = 6
EXEC sp_trace_setfilter @TraceID, 3, 1, 0, @dbId
-- filter2 exclude application SQL Profiler
EXEC sp_trace_setfilter @TraceID, 10, 0, 7, N'SQL Profiler'

-- Start the trace
EXEC sp_trace_setstatus @TraceID, 1
 
-- display trace id for future references 
SELECT TraceID=@TraceID 
GOTO finish 

-- error trap
error: 
SELECT ErrorCode=@rc 

-- exit
finish: 
GO

-- RUN THESE SCRIPTS SEPARATELY TO END THE TRACE
/*

 EXEC sp_trace_setstatus 2, 0
 EXEC sp_trace_setstatus 2, 2

*/