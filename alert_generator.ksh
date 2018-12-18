#!/bin/ksh
#
################################################################################
# alert_generator.ksh
#  Examples:
# sh alert_generator.ksh -e dev
#
# Modification History
#
# Date:      Name:		Desc:
# ---------- ---------- -------------------------------------------------------
# 10/14/2014 Jerome		Created
################################################################################
#
#
Usage()
{
	echo "Usage: $1 -e environment [-h]"
	exit
}

FileCLNUP()
{
	# remove files and logs > 3 days old
	echo `date` "Removing these files:"
	find ${log_dir}  -name "$1*" -mtime +3 -exec ls -lt {} \;
	find ${log_dir}  -name "$1*" -mtime +3 -exec rm {} \;
	echo "Log file for alert process removed"
}

GenerateAlert()
{
touch ${log_dir}/TmpMailFile
NotList=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT LISTAGG(ALRT_KEY,' ') WITHIN GROUP (ORDER BY ALRT_KEY) FROM
(SELECT DISTINCT ALRT_KEY FROM ALRT_LOG_TBL WHERE SWEEP_IND='Y');
ENDSQL`

for i in $NotList
do
RecList=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT ALRT_RCPNT FROM ALRT_REF_TBL WHERE ALRT_KEY=$i;
ENDSQL`

Subject=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT ALRT_SUBJ FROM ALRT_REF_TBL WHERE ALRT_KEY=$i;
ENDSQL`

MailHdr=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT ALRT_MSG FROM ALRT_REF_TBL WHERE ALRT_KEY=$i;
ENDSQL`

FldCnt=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT 
regexp_count(COL_META,'[^|]+')
FROM ALRT_REF_TBL WHERE ALRT_KEY=$i;
ENDSQL`

echo "From: DemoUser@Demo.com" > ${log_dir}/TmpMailFile
echo "To: " $RecList >> ${log_dir}/TmpMailFile
echo "MIME-Version: 1.0" >> ${log_dir}/TmpMailFile
echo "Content-Type: text/html" >> ${log_dir}/TmpMailFile
echo "Subject: " $Subject >> ${log_dir}/TmpMailFile
echo "<html><body><p>" $MailHdr"</p><table border=1 cellspacing=0 cellpadding=3>" >> ${log_dir}/TmpMailFile

echo "<tr>" >> ${log_dir}/TmpMailFile
for k in {1..$FldCnt}
do
Fld=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
SELECT regexp_substr(COL_META,'[^|]+',1,$k) FROM ALRT_REF_TBL WHERE ALRT_KEY=$i;
ENDSQL`
echo "<td><b>"$Fld"</b></td>" >> ${log_dir}/TmpMailFile
done
echo "</tr>" >> ${log_dir}/TmpMailFile

MailBodyAggrCursor=`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set serveroutput on
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
DECLARE
vAlrtKeys clob;
  procedure print_clob( p_clob in clob ) is
      v_offset number default 1;
      v_chunk_size number := 32767;
  begin
      loop
          exit when v_offset > dbms_lob.getlength(p_clob);
          dbms_output.put_line( dbms_lob.substr( p_clob, v_chunk_size, v_offset ) );
          v_offset := v_offset +  v_chunk_size;
      end loop;
  end print_clob;
BEGIN
FOR j IN (SELECT ALRT_LOG_KEY FROM ALRT_LOG_TBL WHERE ALRT_KEY=$i AND SWEEP_IND='Y')
LOOP
SELECT vAlrtKeys||ALRT_LOG_KEY||' ' INTO vAlrtKeys FROM ALRT_LOG_TBL WHERE ALRT_KEY=$i AND SWEEP_IND='Y' AND ALRT_LOG_KEY=j.ALRT_LOG_KEY;
END LOOP;
print_clob(vAlrtKeys);
END;
/
ENDSQL`

#LISTAGG not used because the aggregation of all the data may exceed 4000 characters. LISTAGG returns VARCHAR2(4000). XMLAGG can be used but can be difficult to manage
MailBody=""
for j in $MailBodyAggrCursor
do
SelStmt="SELECT '<tr>'||CHR(10)||"
for m in {1..$FldCnt}
do
SelStmt=$SelStmt"'<td>'||regexp_substr(col_data,'[^|]+',1,$m)||'</td>'||CHR(10)||"
done
SelStmt=$SelStmt"'</tr>'||CHR(10) FROM ALRT_LOG_TBL WHERE ALRT_LOG_KEY=$j;"

echo $SelStmt > TmpAlrtSql.sql

MailBody=$MailBody`sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
@TmpAlrtSql.sql
ENDSQL`
done

echo $MailBody >> ${log_dir}/TmpMailFile
echo "</table>" >> ${log_dir}/TmpMailFile
echo "<p>Thank You</p></body></html>" >> ${log_dir}/TmpMailFile

cat ${log_dir}/TmpMailFile | /usr/sbin/sendmail -t

done

sqlplus -s ${OID}/${OPSWD}<<ENDSQL
set head off
set linesize 400
set pagesize 0 feedback off verify off  heading off echo off trimspool on colsep |
UPDATE ALRT_LOG_TBL
SET SWEEP_IND='N';
COMMIT;
EXIT;
/
ENDSQL
}
################################################################################
#
# Begin Here:
#  - process cmdline flags
#  - set env vars
#  - cleanup old files
#
################################################################################

#  process cmdline flags
while getopts e:h val
do
   case $val in
        e)      eflag=1;
                export env=`echo ${OPTARG} | tr "[a-z]" "[A-Z]"`;;
        h)      hflag=1;;       # help
        *)      Usage $0;;
   esac
done

if [ "$hflag" ]; then
   head -$(($(grep -n "Modification History" $0 | sed 2,\$d | \
   cut -f1 -d:)-1)) $0
   Usage $0
fi

[[ -z "$eflag" ]] && printf "Option -e must be specified\n" && Usage $0

set -o xtrace

#Conceal passwords in an environment file and source the file within the script
export OID=UserName@ServerName
export OPSWD=password
export OSCH=SchemaName
export script='alert_generator'
export dttm=`date '+%Y%m%d%H%M%S'`
export log_dir=${log_dir}/EDI852
export status='Success'


exec > ${log_dir}/${script}_${dttm}.log 2>&1 
FileCLNUP ${script}
GenerateAlert