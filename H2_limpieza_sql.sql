/* ============================================================================
   H1/H2 - PLANTILLA DE LIMPIEZA EN SQL SERVER (T-SQL)
   Delfosti - Medios de Pago
   Plantilla reutilizable: cargar staging (texto) -> ejecutar -> tabla limpia.
   Re-ejecutable (idempotente). Mismas reglas que el pipeline Python.
============================================================================ */
IF DB_ID('DelfostiH2') IS NULL CREATE DATABASE DelfostiH2;
GO
USE DelfostiH2;
GO

/* ---- STAGING: todo NVARCHAR para recibir la data cruda sin perdida ---- */
DROP TABLE IF EXISTS dbo.PropuestasStaging;
CREATE TABLE dbo.PropuestasStaging (
    Codigo NVARCHAR(50), FechaOferta NVARCHAR(50), FechaRespuesta NVARCHAR(50),
    Segmento NVARCHAR(50), ActividadEconomica NVARCHAR(100),
    Tarifa1 NVARCHAR(50), Tarifa2 NVARCHAR(50), Tarifa3 NVARCHAR(50),
    Share1 NVARCHAR(50), Share2 NVARCHAR(50), Share3 NVARCHAR(50),
    Departamento NVARCHAR(50),
    TarifaComp1 NVARCHAR(50), TarifaComp2 NVARCHAR(50), TarifaComp3 NVARCHAR(50)
);
GO
/* Carga: Import Flat File (SSMS) o:
   BULK INSERT dbo.PropuestasStaging FROM 'C:\ruta\H1_Dataset_staging.csv'
   WITH (FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK); */

/* ===================== FUNCIONES DE LIMPIEZA ===================== */
GO
CREATE OR ALTER FUNCTION dbo.fn_Num (@v NVARCHAR(50)) RETURNS DECIMAL(10,4) AS
BEGIN  -- coma decimal/%/texto basura -> decimal | NULL
    RETURN TRY_CONVERT(DECIMAL(10,4),
           NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(@v,'%',''),',','.'))),''));
END;
GO
CREATE OR ALTER FUNCTION dbo.fn_Fecha (@v NVARCHAR(50)) RETURNS DATE AS
BEGIN  -- multi-formato incl. dd-MMM-yy (es/en) -> DATE | NULL
    DECLARE @s NVARCHAR(50)=LTRIM(RTRIM(@v)), @r DATE;
    IF @s LIKE '[0-9]%-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]'
        RETURN DATEFROMPARTS(RIGHT(@s,2)+2000,
            CASE LOWER(SUBSTRING(@s,CHARINDEX('-',@s)+1,3))
              WHEN 'ene' THEN 1 WHEN 'jan' THEN 1 WHEN 'feb' THEN 2 WHEN 'mar' THEN 3
              WHEN 'abr' THEN 4 WHEN 'apr' THEN 4 WHEN 'may' THEN 5 WHEN 'jun' THEN 6
              WHEN 'jul' THEN 7 WHEN 'ago' THEN 8 WHEN 'aug' THEN 8 WHEN 'sep' THEN 9
              WHEN 'oct' THEN 10 WHEN 'nov' THEN 11 WHEN 'dic' THEN 12 WHEN 'dec' THEN 12 END,
            LEFT(@s,CHARINDEX('-',@s)-1));
    SET @r=COALESCE(TRY_CONVERT(DATE,@s,103), TRY_CONVERT(DATE,REPLACE(@s,'-','/'),103),
                    TRY_CONVERT(DATE,@s,111), TRY_CONVERT(DATE,@s,23));
    RETURN @r;
END;
GO
CREATE OR ALTER FUNCTION dbo.fn_Actividad (@v NVARCHAR(100)) RETURNS NVARCHAR(100) AS
BEGIN  -- canoniza typos/acentos/mayusculas
    DECLARE @x NVARCHAR(100)=LOWER(LTRIM(RTRIM(@v)));
    SET @x=REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@x,N'á','a'),N'é','e'),N'í','i'),N'ó','o'),N'ú','u');
    RETURN CASE @x
        WHEN 'alimentacion' THEN N'Alimentación' WHEN 'entretenimiento' THEN N'Entretenimiento'
        WHEN 'farmacia' THEN N'Farmacia' WHEN 'ferreteria' THEN N'Ferretería'
        WHEN 'gasolinera' THEN N'Gasolinera' WHEN 'gasolineras' THEN N'Gasolinera'
        WHEN 'mayorista' THEN N'Mayorista' WHEN 'moda' THEN N'Moda'
        WHEN 'restaurante' THEN N'Restaurante' WHEN 'restaurant' THEN N'Restaurante'
        WHEN 'tecnologia' THEN N'Tecnología' ELSE @v END;
END;
GO
CREATE OR ALTER FUNCTION dbo.fn_Titulo (@v NVARCHAR(50)) RETURNS NVARCHAR(50) AS
BEGIN
    DECLARE @s NVARCHAR(50)=LTRIM(RTRIM(@v));
    RETURN UPPER(LEFT(@s,1))+LOWER(SUBSTRING(@s,2,50));
END;
GO

/* ===================== CONSTRUCCION DE TABLA LIMPIA ===================== */
DROP TABLE IF EXISTS dbo.PropuestasLimpia;
WITH Cast_ AS (
    SELECT LTRIM(RTRIM(Codigo)) Codigo,
           dbo.fn_Fecha(FechaOferta) FechaOferta, dbo.fn_Fecha(FechaRespuesta) FechaRespuesta,
           dbo.fn_Titulo(Segmento) Segmento, dbo.fn_Actividad(ActividadEconomica) Actividad,
           dbo.fn_Num(Tarifa1) T1, dbo.fn_Num(Tarifa2) T2, dbo.fn_Num(Tarifa3) T3,
           IIF(dbo.fn_Num(Share1)<0,NULL,dbo.fn_Num(Share1)) S1,   -- shares negativos -> NULL
           IIF(dbo.fn_Num(Share2)<0,NULL,dbo.fn_Num(Share2)) S2,
           IIF(dbo.fn_Num(Share3)<0,NULL,dbo.fn_Num(Share3)) S3,
           dbo.fn_Titulo(Departamento) Departamento,
           dbo.fn_Num(TarifaComp1) C1, dbo.fn_Num(TarifaComp2) C2, dbo.fn_Num(TarifaComp3) C3
    FROM dbo.PropuestasStaging
),
Med AS (  -- mediana de tarifas por rubro (para imputacion)
    SELECT DISTINCT Actividad,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY T1) OVER(PARTITION BY Actividad) MT1,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY T2) OVER(PARTITION BY Actividad) MT2,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY T3) OVER(PARTITION BY Actividad) MT3,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY C1) OVER(PARTITION BY Actividad) MC1,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY C2) OVER(PARTITION BY Actividad) MC2,
           PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY C3) OVER(PARTITION BY Actividad) MC3
    FROM Cast_
),
Imp AS (  -- imputacion + suma de shares para renormalizar
    SELECT c.Codigo, c.FechaOferta, c.FechaRespuesta, c.Segmento, c.Actividad,
           ISNULL(c.T1,m.MT1) T1, ISNULL(c.T2,m.MT2) T2, ISNULL(c.T3,m.MT3) T3,
           c.S1, c.S2, c.S3, c.Departamento,
           ISNULL(c.C1,m.MC1) C1, ISNULL(c.C2,m.MC2) C2, ISNULL(c.C3,m.MC3) C3,
           (ISNULL(c.S1,0)+ISNULL(c.S2,0)+ISNULL(c.S3,0)) SumaS
    FROM Cast_ c LEFT JOIN Med m ON c.Actividad=m.Actividad
)
SELECT Codigo, FechaOferta, FechaRespuesta, Segmento, Actividad AS ActividadEconomica,
       T1 AS Tarifa1, T2 AS Tarifa2, T3 AS Tarifa3,
       IIF(SumaS>0, ROUND(S1/SumaS*100,3), NULL) AS Share1,
       IIF(SumaS>0, ROUND(S2/SumaS*100,3), NULL) AS Share2,
       IIF(SumaS>0, ROUND(S3/SumaS*100,3), NULL) AS Share3,
       Departamento, C1 AS TarifaComp1, C2 AS TarifaComp2, C3 AS TarifaComp3,
       DATEDIFF(DAY,FechaOferta,FechaRespuesta) AS DiasRespuesta,
       ROUND(T1*S1/SumaS + T2*S2/SumaS + T3*S3/SumaS, 3) AS TarifaEfectiva,
       ROUND((C1+C2+C3)/3.0, 3) AS TarifaCompetenciaProm,
       ROUND(T1*S1/SumaS+T2*S2/SumaS+T3*S3/SumaS - (C1+C2+C3)/3.0, 3) AS GapVsCompetencia,
       DATEFROMPARTS(YEAR(FechaOferta),MONTH(FechaOferta),1) AS MesOferta
INTO dbo.PropuestasLimpia
FROM Imp;
GO

/* ===================== GATE DE CALIDAD ===================== */
SELECT COUNT(*) Filas,
       COUNT(*)-COUNT(DISTINCT Codigo)        IdDuplicados,
       SUM(IIF(FechaOferta IS NULL,1,0))      FechasNulas,
       SUM(IIF(Tarifa1 IS NULL OR Tarifa2 IS NULL OR Tarifa3 IS NULL,1,0)) TarifasNulas,
       SUM(IIF(DiasRespuesta<0,1,0))          RespuestaAntesOferta,
       COUNT(DISTINCT ActividadEconomica)     CategoriasActividad
FROM dbo.PropuestasLimpia;
GO

/* ===================== HALLAZGOS DE PRICING ===================== */
SELECT ActividadEconomica, COUNT(*) Propuestas,
       ROUND(AVG(TarifaEfectiva),3)   TarifaEfectivaProm,
       ROUND(AVG(GapVsCompetencia),3) GapVsCompetenciaProm
FROM dbo.PropuestasLimpia
GROUP BY ActividadEconomica
ORDER BY GapVsCompetenciaProm DESC;
GO
