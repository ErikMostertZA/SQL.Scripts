RETRY:
BEGIN TRANSACTION
BEGIN TRY

	--DO SOMETHING HERE...

	COMMIT TRANSACTION
END TRY
BEGIN CATCH
	ROLLBACK TRANSACTION
	IF ERROR_NUMBER() = 1205
	BEGIN
		WAITFOR DELAY '00:00:00.05'
		GOTO RETRY
	END
END CATCH