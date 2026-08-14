libname shop "/home/student/shop_db";

%LET CSVDIR = /home/student/shop_csv;

/*csv to sas macro*/
 %MACRO imp(name=);
	proc import datafile="&csvdir/&name..csv"
		out=shop.&name
		dbms=csv REPLACE;
	GETNAMES=YES;
	GUESSINGROWS=MAX;
	RUN;
%put Note: ====&name..csv -> shop.&name 변환 완료 =====;
%mend;

	%imp(name=users);
	%imp(name=orders);
	%imp(name=order_items);
	%imp(name=products);
	%imp(name=campaigns);

/*DB 생성 완료*/

/* 데이터를 받으면 항상 구조를 contents로 비교 */

proc contents data