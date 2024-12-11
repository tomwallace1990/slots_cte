CREATE PROCEDURE [STAGING].[PopulateScheduleReportSlots]
@days INT = 30

AS
BEGIN

-- Generate slots
WITH ScheduleRuns AS (
	SELECT 
            sch.query_id,
            CASE -- This block works out if the start datetime is more than X (30) days ago
			    WHEN sch.start_utc > CAST(CONVERT(varchar, DATEADD(day, -@days, GETDATE()), 23) + ' ' + CONVERT(varchar, sch.start_utc, 108) AS datetime)
			    THEN sch.start_utc -- If not then take the start date unchanged
			    ELSE CAST(CONVERT(varchar, DATEADD(day, -@days, GETDATE()), 23) + ' ' + CONVERT(varchar, sch.start_utc, 108) AS datetime) -- If it is then set the start to the date to 30 days ago but with the time component from the original datetime
			END AS run_time_user,
            sch.start_utc,
            sch.end_utc,
            sch.frequency_mins,
			tz.offset as timezone_offset,
			CASE -- This block works out if we need to apply a DST offset like +1 for British Summer Time
				WHEN sch.end_utc > sav.start_date AND sch.end_utc < sav.end_date
				THEN sav.offset
				ELSE 0
			END as savings_offset, 
            1 AS slot_number
        FROM [STAGING].[schedule] AS sch
		JOIN [STAGING].[query] AS q on q.query_id = sch.query_id
		JOIN [STAGING].[user] AS u ON u.user_id = q.user_id
		JOIN [STAGING].[time_zones] AS tz ON tz.time_zone_id = u.time_zone_id
		JOIN [STAGING].[time_zones_savings_regimes] AS sav ON sav.savings_regime_id = tz.savings_regime_id
        WHERE 
            sch.is_enabled = 1 AND 
            sch.is_deleted = 0 AND 
            sch.frequency_mins > 5 AND -- Recursing a schedule of less than 5 minutes would be bad!
		    sch.start_utc < GETDATE() AND -- Only schedules which start in the past as these are retrospective reports
		    sch.end_utc > DATEADD(DAY, -@days, GETDATE()) -- Ignore schedules which ended over 30 days ago
	UNION ALL
        SELECT 
            sr.query_id,
            DATEADD(minute, sr.frequency_mins, sr.run_time_user) AS run_time, -- Add the freq to the run time to iteratively generate slots
            sr.start_utc,
            sr.end_utc,
            sr.frequency_mins,
			sr.timezone_offset,
			sr.savings_offset,
            sr.slot_number + 1 -- Incitement the slot number
        FROM 
            ScheduleRuns sr
        WHERE 
            DATEADD(minute, sr.frequency_mins, sr.run_time_user) <= DATEADD(DAY, 1 , GETDATE()) -- Stop when we reach the current datetime + 1 day to account for different timezones, extra chopped off later
		    AND sr.run_time_user <= sr.end_utc -- Stop once the generated slots hit the end of each given schedule)

-- Insert from generated CTE
INSERT INTO [STAGING].[schedule_report_slots] ([query_id], [slot_start_time_user], [slot_end_time_user], [slot_start_time_utc], [slot_end_time_utc], [frequency_mins], [schedule_start_user], [schedule_end_user], [slot_generated_at])
    SELECT 
        sr.query_id,
	    DATEADD(MINUTE, -sr.frequency_mins, sr.run_time_user) as slot_start_time_user, -- subtract the interval mins from the end time to get the start time (should equal the end time of the previous slot)
	    sr.run_time_user as slot_end_time_user, -- AKA report/slot run time, this is the number the user expects to see and when the old email report would have been sent
	    DATEADD(MINUTE, -sr.savings_offset, DATEADD(MINUTE, -sr.timezone_offset, DATEADD(MINUTE, -sr.frequency_mins, sr.run_time_user))) as slot_start_time_utc, -- This is the slot start time but with the timezone and savings removed to convert to UTC
	    DATEADD(MINUTE, -sr.savings_offset, DATEADD(MINUTE, -sr.timezone_offset, sr.run_time_user)) as slot_end_time_utc, -- This is the slot end time but with the timezone and savings removed to convert to UTC
	    sr.frequency_mins,
        sr.start_utc, -- This is the start datetime of the schedule itself, not our slots. Every slot for a given schedule will have the same time here
		sr.end_utc, -- Same as above for end time
        GETDATE() as slot_generated_at -- for audit/debugging, server is in UTC so this time is always without timezones/DST
    FROM 
        ScheduleRuns sr
    WHERE -- This second set of where clauses is much more granular because performance is less of a concern outside of the CTE recursion
		run_time_user <= end_utc -- This stop slots from after the schedule ends (if it is in the past)
		AND sr.run_time_user >= DATEADD(MINUTE, sr.savings_offset, DATEADD(MINUTE, sr.timezone_offset, DATEADD(DAY, -@days, GETDATE()))) -- This works out the datetime X days ago from the users perspective and only allows rows greater than that time
		AND sr.run_time_user <= DATEADD(MINUTE, sr.savings_offset, DATEADD(MINUTE, sr.timezone_offset, GETDATE())) -- This works out the user's current datetime and only allows slots before that to avoid ones in the future 
		AND NOT EXISTS (
			SELECT 1 
			FROM [STAGING].[schedule_report_slots] as srs -- This works out if the row already exists on the destination table
			WHERE srs.query_id = sr.query_id 
			AND  srs.slot_end_time_user >= sr.run_time_user) -- This disallows inserting of any slot older than the most recent slot on the table which prevents the user changing periods causing an issue
    ORDER BY 
        sr.query_id, sr.run_time_user ASC

    OPTION (MAXRECURSION 32767); -- This is the max recursion supported by SQL, max value of 16 bit signed int, we should never come close to this

-- Delete old slots
DELETE FROM [STAGING].[schedule_report_slots]
WHERE slot_end_time_utc < DATEADD(DAY, -@days, GETDATE()) -- Using the calculated UTC slot time here so this should be accurate for any given customer timezone down to the second

DELETE FROM [STAGING].[schedule_report_slots_user_status] -- Delete from the supplementary status table
WHERE slot_id NOT IN (SELECT slot_id from [STAGING].[schedule_report_slots]) -- NOT IN is not super efficient but the table should never be that large

END
GO