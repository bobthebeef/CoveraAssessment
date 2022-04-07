/*
Assumption(s):
	All study data and study_id's all represent spine MRI's. 
	Since no crosswalk/dimension was provided describing the studyID's, I can only assume that per the instructions, 
	each particular imaging study represents a spine MRI.

	It is unclear what "repeat imaging" is to me, so I have defined it as a patient having multiple studies in the StudyData dataset.


*/
use CoveraChallenge
/*
Question 1 - SUmmary of rate of spine MRI imaging at hospitals vs. community settings
Will look at zip code. I used a source here to map zip codes:
http://www.uszipcodelist.com/download.html
This has been moved to raw.zip_code_database. I will create an index on this table and then just use it downstream to determine state
via a direct join
*/

--CREATE CLUSTERED INDEX IX_Zip ON raw.zip_code_database (zip)
--CREATE NONCLUSTERED INDEX IX_Zip_Inc_State ON (Zip) INCLUDE(State)
select * FROM [raw].[zip_code_database]
DROP TABLE IF EXISTS #HospitalByRegion
select CASE WHEN b.state IS NULL THEN 'UNK' ELSE b.State END State,count(1) StudyEvents,SUM(a.Cost) TotalDownstreamCost
INTO #HospitalByRegion
FROM dbo.studydata_cleansed a
LEFT OUTER join [raw].[zip_code_database] b
on a.Zip=b.Zip
WHERE a.IsHospital=1
GROUP BY b.State
--only 201 unknown zipcode states, likely due to discreps with the external source I used for zip codes. Studies all took place in IN,IL,MI,OH,FL
DROP TABLE IF EXISTS dbo.HospitalSummaryByRegion
select *,CAST(TotalDownstreamCost AS DECIMAL(18,4))/CAST(StudyEvents AS DECIMAL(18,4)) DownstreamCostPerEvent_Hospital
INTO dbo.HospitalSummaryByRegion
FROM #HospitalByRegion

DROP TABLE IF EXISTS #CommunityByRegion
select CASE WHEN b.state IS NULL THEN 'UNK' ELSE b.State END State,count(1) StudyEvents,SUM(a.Cost) TotalDownstreamCost
INTO #CommunityByRegion
FROM dbo.studydata_cleansed a
LEFT OUTER join [raw].[zip_code_database] b
on a.Zip=b.Zip
WHERE a.IsHospital=0
GROUP BY b.State


DROP TABLE IF EXISTS dbo.CommunitySummaryByRegion
select *,CAST(TotalDownstreamCost AS DECIMAL(18,4))/CAST(StudyEvents AS DECIMAL(18,4)) DownstreamCostPerEvent_Community
INTO dbo.CommunitySummaryByRegion
FROM #CommunityByRegion

SELECT * FROM dbo.CommunitySummaryByRegion
SELECT * FROM dbo.HospitalSummaryByRegion

SELECT a.State,a.DownstreamCostPerEvent_Community,b.DownstreamCostPerEvent_Hospital,CAST(100*(CAST(DownstreamCostPerEvent_Community AS DECIMAL(18,4))-CAST(DownstreamCostPerEvent_Hospital AS DECIMAL(18,4)))/CAST(DownstreamCostPerEvent_Hospital AS DECIMAL(18,4))AS DECIMAL(18,4)) CommunitySavings 
FROM dbo.CommunitySummaryByRegion a
INNER JOIN dbo.HospitalSummaryByRegion b
ON a.State=b.State

--Question 2 - what features are associated with repeat imaging
DROP TABLE IF EXISTS dbo.RepeatImaging
SELECT patientid,CASE WHEN b.state IS NULL THEN 'UNK' ELSE b.State END State,count(1) StudyEvents
INTO dbo.RepeatImaging
FROM dbo.StudyData_Cleansed a
LEFT OUTER JOIN raw.zip_code_database b
ON a.zip=b.zip
group by patientid,state
HAVING COUNT(1)>1
--there are no studyids repeated, so the ASSUMPTION will be that repeat imaging is the same patient being imaged multiple times

SELECT * FROM dbo.RepeatImaging
CREATE CLUSTERED INDEX IX_PK ON dbo.RepeatImaging (patientid)

--Repeat Imaging by weight and age

--Create basic Age dimension
DROP TABLE IF EXISTS dbo.Age
CREATE TABLE dbo.Age (MinAge INT,MaxAge INT,AgeGroup VARCHAR(10))
INSERT INTO dbo.Age (MinAge,MaxAge,AgeGroup)
VALUES
(0,19,'0-19'),
(20,29,'20-29'),
(30,39,'30-39'),
(40,49,'40-49'),
(50,59,'50-59'),
(60,69,'60-69'),
(70,1000,'70+')

--Create Basic BMI dimension
DROP TABLE IF EXISTS dbo.BMI
CREATE TABLE dbo.BMI (MinBMI DECIMAL(18,4),MaxBMI DECIMAL(18,4),BMIGroup VARCHAR(30))
INSERT INTO dbo.BMI (MinBMI,MaxBMI,BMIGroup)
VALUES
(0.0,18.0,'UNDERWEIGHT'),
(18.0001,25.0,'NORMAL'),
(25.0001,29.9999,'OVERWEIGHT'),
(30.0,39.9,'OBESE'),
(40.0,1000.0,'MORBIDLY OBESE')


select * FROM dbo.bmi


SELECT a.*,c.AgeGroup,CAST(weight/((height/100.0)*(height/100.0)) AS INT) BMI,d.BMIGroup 
FROM dbo.RepeatImaging a
INNER JOIN dbo.PatientData_Cleansed b
on a.PatientID=b.PatientID
INNER JOIN dbo.Age c
ON b.age BETWEEN c.MinAge and c.MaxAge
LEFT OUTER JOIN dbo.BMI d
ON CAST(CAST(weight AS FLOAT)/((height/100.0)*(height/100.0)) AS FLOAT) BETWEEN CAST(d.MinBMI AS DECIMAL(18,4)) and CAST(d.MaxBMI AS DECIMAL(18,4))


DROP TABLE IF EXISTS dbo.TotalPatientsByAge
SELECT AgeGroup,COUNT(1) Patients
INTO dbo.TotalPatientsByAge
FROM dbo.PatientData_Cleansed a
inner join dbo.Age b
on a.age between b.MinAge and b.maxage
group by AgeGroup

SELECT * FROM TotalPatientsByAge

DROP TABLE IF EXISTS dbo.RepeatImagingByAge
SELECT AgeGroup,COUNT(1) Patients
INTO dbo.RepeatImagingByAge
FROM dbo.RepeatImaging a
INNER JOIN dbo.PatientData_Cleansed b
on a.PatientID=b.PatientID
INNER JOIN dbo.Age c
ON b.age BETWEEN c.MinAge and c.MaxAge
group by AgeGroup


SELECT a.AgeGroup,a.Patients TotalPatients,b.Patients RepeatPatients,100.0*CAST(b.Patients AS DECIMAL(18,4))/CAST(a.Patients AS DECIMAL(18,4)) WeightedAgeScore FROM TotalPatientsByAge a
INNER JOIN RepeatImagingByAge b
ON A.AgeGroup=b.AgeGroup

DROP TABLE IF EXISTS dbo.TotalStudyEventsByState
SELECT CASE WHEN b.state IS NULL THEN 'UNK' ELSE b.State END State,count(1) TotalStudyEvents
INTO dbo.TotalStudyEventsByState
FROM dbo.StudyData_Cleansed a
LEFT OUTER JOIN raw.zip_code_database b
on a.Zip=b.zip
group by state

select * FROM TotalStudyEVentsByState

DROP TABLE IF EXISTS dbo.RepeatImagingByState
SELECT State,COUNT(1) RepeatsByState 
INTO dbo.RepeatImagingByState
FROM dbo.RepeatImaging a
GROUP BY State

SELECT a.State,a.RepeatsByState,b.TotalStudyEvents,100.0*(CAST(RepeatsByState AS DECIMAL(18,4))/CAST(TotalStudyEvents AS DECIMAL(18,4))) WeightedAverage 
FROM RepeatImagingByState a
INNER JOIN TotalStudyEventsByState b
ON a.State=b.State
ORDER BY WeightedAverage

--Question 3 features associated with emergency room setting
DROP TABLE IF EXISTS dbo.ErImaging
SELECT a.*,CASE WHEN b.state IS NULL THEN 'UNK' ELSE b.State END State
INTO dbo.ErImaging
FROM dbo.StudyData_Cleansed a
LEFT OUTER JOIN raw.zip_code_database b
ON a.zip=b.zip
WHERE a.iser=1
--39,237 total ER events
--100% of ER visits are also hospital visits, which makes sense

DROP TABLE IF EXISTS dbo.ErImaging_WeightAge
SELECT a.PatientID,a.state,c.AgeGroup,CAST(weight/((height/100.0)*(height/100.0)) AS INT) BMI,d.BMIGroup
INTO dbo.ErImaging_WeightAge
FROM dbo.ErImaging a
INNER JOIN dbo.PatientData_Cleansed b
on a.PatientID=b.PatientID
INNER JOIN dbo.Age c
ON b.age BETWEEN c.MinAge and c.MaxAge
INNER JOIN dbo.BMI d
ON CAST(CAST(weight AS FLOAT)/((height/100.0)*(height/100.0)) AS FLOAT) BETWEEN CAST(d.MinBMI AS DECIMAL(18,4)) and CAST(d.MaxBMI AS DECIMAL(18,4))

SELECT PatientID,count(1) FROM dbo.ErImaging_WeightAge
group by PatientID
having count(1)>1
--there are only 23 repeat ER visits in this set out of 39,000 which is good. We would not want multiple screenings in the ER as a large % of the population
--with a result set so small, it's not something that I think we need to examine for systemic issues

--baseline BMI check
SELECT * FROM dbo.ErImaging_WeightAge
WHERE BMI>25
--only 114 rows, no obese patients in the entire set. Here too as with the others, BMI does not appear to have a significant correlation to ER visits, and 
--there don't seem to be any obese patients in the data set.

DROP TABLE IF EXISTS dbo.ErEventsByState
SELECT State,COUNT(1) Events
INTO dbo.ErEventsByState
FROM dbo.ErImaging_WeightAge
GROUP BY State

select * FROM TotalStudyEventsByState

--ErEventsByState.csv
DROP TABLE IF EXISTS ErEventsByState_Output
SELECT a.State,b.TotalStudyEvents,100.0*(CAST(Events AS DECIMAL(18,4))/CAST(TotalStudyEvents AS DECIMAL(18,4))) WeightedAverage
INTO ErEventsByState_Output
FROM dbo.ErEventsByState a
INNER JOIN TotalStudyEventsByState b
ON a.State=b.State
ORDER BY WeightedAverage




DROP TABLE IF EXISTS dbo.ErEventsByAgeState
SELECT a.AgeGroup,a.State,COUNT(1) Patients
INTO dbo.ErEventsByAgeState
FROM dbo.ErImaging_WeightAge a
INNER JOIN dbo.PatientData_Cleansed b
on a.PatientID=b.PatientID
INNER JOIN dbo.Age c
ON b.age BETWEEN c.MinAge and c.MaxAge
group by a.AgeGroup,a.State
ORDER BY State,AgeGroup

DROP TABLE IF EXISTS ErImagingState
select state,count(1) Events 
INTO ErImagingState
FROM ErImaging
group by state


--ErEventsByStateAndAge.csv
DROP TABLE IF EXISTS ErEventsByAgeState_Output
SELECT a.AgeGroup,a.State,a.Patients,b.Events TotalEvents,100.0*(CAST(Patients AS DECIMAL(18,4))/CAST(Events AS DECIMAL(18,4))) Weight
--INTO ErEventsByAgeState_Output
FROM ErEventsByAgeState a
INNER JOIN erimagingstate b
on a.state=b.state

DROP TABLE IF EXISTS TotalEventsByAge
SELECT AgeGroup,count(1) Events
INTO TotalEventsByAge
FROM StudyData_Cleansed a
INNER JOIN PatientData_Cleansed b
on a.PatientID=b.PatientID
INNER JOIN Age c
ON b.age BETWEEN c.MinAge and c.MaxAge
GROUP BY AgeGroup

DROP TABLE IF EXISTS ErEventsByAge
SELECT AgeGroup,SUM(Patients) Patients
INTO ErEventsByAge
FROM ErEventsByAgeState a
GROUP BY AgeGroup

DROP TABLE IF EXISTS ErEventsByAge_Output
SELECT a.AgeGroup,a.Patients ErEvents,b.Events TotalEvents,100.0*(CAST(Patients AS DECIMAL(18,4))/CAST(Events AS DECIMAL(18,4))) ErPercentage 
INTO ErEventsByAge_Output
FROM ErEventsByAge a
INNER JOIN TotalEventsByAge b
ON a.AgeGroup=b.AgeGroup



