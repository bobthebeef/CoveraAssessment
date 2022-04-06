/*
Importing the raw data into the raw schema. raw.patientdata and raw.studydata
Now will analyze and cleanse data now that we have them in logical tables.
*/

--take a look at the data, create a clustered index.
SELECT * FROM raw.patientdata
--create clustered index ix_pid on raw.patientdata (pid)

--Begin Demographics investigation and cleansing

--Check for patientid dupes. if we find them, will have to see how we deal with them below based on results in the data

SELECT pid,count(1) FROM raw.patientdata
group by pid
having count(1)>1
order by pid
--No dupes, much rejoicing!


--noticing some patents with none or no value for age, will take a look at that
SELECT * FROM raw.patientdata
WHERE ISNUMERIC(age)=0
--interesting, looks like some patients with No age have a 2 digit year of birth. However, Do we assume this number is age or year_of_birth? (eg: someone enters in '80' for year of birth instead of '1980'. Lets take a look...

select * FROM raw.patientdata
where TRY_CAST(year_of_birth as int)<1000
--it looks like in the cases of this particular data set, we are seeing that year_of_birth's 2 digit values appear to be indeed, year of birth and not the age column shifted over.
--I can tell that it appears that year_of_birth and age added together are coming up as 118, or that this data set and age values are effective as of 2018. This appears consistent across this subset of data. 
--pid 1118377 is age 18 and year of birth 0 (2000)
--pid 1120119 has age 63 and year of birth 55 (1955, meaning 63 in calendar year 2018)
--though this will be a crude representation of age, I will run some code to clean this data up and get consistent age as well as year of birth.

--any patients with funny pid values?
SELECT * FROM raw.patientdata
where ISNUMERIC(pid)=0
--nope, rejoice!

--any patients with fully height and weight values?
SELECT * FROM raw.patientdata
where ISNUMERIC(weight)=0

SELECT * FROM raw.patientdata
where ISNUMERIC(height)=0
--Nope and nope!

DROP TABLE IF EXISTS dbo.PatientData_Cleansed
CREATE TABLE dbo.PatientData_Cleansed (PatientID BIGINT,age INT,BirthYear INT,height DECIMAL(18,8),weight DECIMAL(18,8))

--initial insert, will do more cleansing downstream
--INSERT INTO dbo.PatientData_Cleansed (PatientID,age,BirthYear,height,weight)
SELECT CAST(pid AS BIGINT) PatientID,CASE WHEN ISNUMERIC(age)=0 THEN NULL ELSE age END age,TRY_CAST(year_of_birth AS INT) BirthYear,height,weight
FROM raw.patientdata

--CREATE CLUSTERED INDEX IX_PID ON dbo.PatientData_Cleansed (PatientID)

-- ********** Age cleansing **********
--using the assumption found in the discovery above, age will be calculated based on 2018, as data appears consistent with this
--SELECT 2018-BirthYear NewAge,*
UPDATE a set age=2018-BirthYear
FROM dbo.PatientData_Cleansed a
WHERE Age IS NULL
AND LEN(BirthYear)=4
--28,855 rows affected

--total rows with null age were over 30k, so we still have some that need cleansing
SELECT 118-BirthYear newage,*
UPDATE a set age=118-BirthYear
FROM dbo.PatientData_Cleansed a
WHERE Age IS NULL
AND LEN(BIrthYear)=2
--1,129 rows affected

SELECT 18-BirthYear,*
--UPDATE a set age=18-BirthYear
FROM dbo.PatientData_Cleansed a
WHERE Age IS NULL
AND LEN(BIrthYear)=1
--46 rows affected

-- ************ BirthYear Cleansing ******************
select * FROM dbo.PatientData_Cleansed
WHERE BirthYear IS NULL
--birth year all filled in

SELECT 2000+BirthYear NewBirthYear,*
--UPDATE a set BirthYear=2000+BirthYear
FROM dbo.PatientData_Cleansed a
WHERE LEN(BirthYear)=1
--282 rows affected

--most recent 2 digit birth year is 21. age is consistent at 97 and file appears effective as of 2018, no ambiguity here. Running update
SELECT 1900+BirthYear NewBirthYear,*
--UPDATE a set BirthYear=1900+BirthYear
FROM dbo.PatientData_Cleansed a
WHERE LEN(BirthYear)=2
--7,714 rows affected

--double check to see if we got them all
SELECT * FROM dbo.PatientData_Cleansed
WHERE lEN(BirthYear)<>4
--0 rows!
SELECT * FROM dbo.PatientData_Cleansed

/*
End demographics cleansing!
At this point, all patient ages have been set with the assumption that the last 1 or 2 digits of birth year means 19XX or 200X based on existing source data
Age was set where not filled in based on birth year, assuming the age of the patient at some point in calendar year 2018. All data with birth year and age filled in properly lined up to this year.
This is not precise to the day since we don't know birth month, but these assumptions allow us to estimate age and determine birth year with reasonable confidence.
*/

--first check for non numeric values on pid and sid
select * FROM raw.studydata
WHERE ISNUMERIC(pid)=0
--2,002 rows with 'None for PID. These rows will be ignored and not present in dbo.StudyData_Cleansed Below

select * FROM raw.studydata
WHERE TRY_CAST(pid AS INT)<0
--4,054 studies here with pid -1. I can only assume -1 is functionally equivalent to "None" and therefore junk data that will be filtered out below.


select * FROM raw.studydata
WHERE pid is null
--no null/missing values

select * FROM raw.studydata
where isnumeric(sid)=0
--0 rows

select * FROM raw.studydata
where sid is null
--0 rows

--distinct values for the flag fields
SELECT DISTINCT is_ER  FROM raw.studydata
SELECT DISTINCT is_hospital  FROM raw.studydata
--both only have the true and false flags, great!

--looks like we have zips with >5 digits
SELECT * FROM raw.studydata
where len(zip)<5
--all 4,011 of these seem to have just an extra digit at the end that is the same as the previous digit. Can we assume this is user typing an extra key by mistake?
SELECT DISTINCT RIGHT(zip,2) FROM raw.studydata
where len(zip)>5
--in fact, they are all like this. Will transform zip below to use LEFT(Zip,5) 

SELECT * FROM raw.studydata
where len(zip)<5
--0 rows!


--I did see some negative cost as well. Should we just take ABS of cost? lets take a peek
SELECT * FROM raw.studydata
where try_PARSE(cost AS NUMERIC)<0
--4,069 rows. We will assume this is a mistake and treat negative cost as positive cost.
--I wouldnt do this if cost was somehow a representation of the claims adjudication process, which could legitimately represent a negative "cost" depending on the source of truth,
--but for the purposes of the study looking into actual medical spend, I WILL ASSUME NEGATIVE COST IS A MISTAKE AND CONVERT THE VALUE TO POSITIVE BELOW.


--Note: zip code is varchar in definition as zips can have leading 0. eg: 02760
DROP TABLE IF EXISTS dbo.StudyData_Cleansed
CREATE TABLE dbo.StudyData_Cleansed (PatientID BIGINT,StudyID INT,IsEr BIT,IsHospital BIT,Cost INT,Zip VARCHAR(10))

INSERT INTO dbo.StudyData_Cleansed (PatientID,StudyID,IsEr,IsHospital,Cost,Zip)
SELECT pid PatientID,sid StudyID,CASE WHEN is_ER='FALSE' THEN 0 WHEN is_ER='TRUE' THEN 1 ELSE NULL END IsER,CASE WHEN is_hospital='FALSE' THEN 0 WHEN is_hospital='TRUE' THEN 1 ELSE NULL END IsHospital,ABS(TRY_PARSE(Cost AS NUMERIC)) Cost,LEFT(Zip,5) Zip 
from raw.studydata
WHERE 1=1
--filter out junk data
AND ISNUMERIC(pid)=1
AND TRY_CAST(pid AS INT)>0
--193,944 rows affected

--CREATE CLUSTERED INDEX IX_PK ON dbo.StudyData_Cleansed (PatientID,StudyID)

/*
End Study Data Cleansing! Based on assumptions above:
	-Negative cost converted to positive cost in insert statement above
	-Zip codes with an extra identical digit to the left of it were the entirety of the 6 digit zips. Used LEFT(Zip,5) as a transform
	-193,944 total events in the study
*/

--6,056 rows of junk data filtered out (unknown patientid)

--post load cleansing. Are there any patients that can't join back to demographics?
SELECT * 
FROM dbo.StudyData_Cleansed sd
LEFT OUTER JOIN dbo.PatientData_Cleansed pd
ON sd.PatientID=pd.PatientID
WHERE pd.PatientID IS NULL
--none, great! we should be able to assess 100% of the study data against the patient dimension

SELECT *
FROM dbo.StudyData_Cleansed sd
INNER JOIN dbo.PatientData_Cleansed pd
ON sd.PatientID = pd.PatientID