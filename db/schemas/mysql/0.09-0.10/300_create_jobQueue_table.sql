--
-- for comments refer to  ../0.10/100-smt-tables.sql
--

alter table Clients add COLUMN ID INTEGER UNSIGNED AUTO_INCREMENT UNIQUE KEY FIRST;

alter table MachineData add COLUMN TYPE INTEGER UNSIGNED NOT NULL default 0;

create table JobQueue ( ID          INTEGER UNSIGNED NOT NULL,
                        GUID_ID     INTEGER UNSIGNED NOT NULL,
                        PARENT_ID   INTEGER UNSIGNED NULL default NULL,
                        NAME        CHAR NOT NULL default '',
                        DESCRIPTION MEDIUMTEXT,
                        TYPE        INTEGER UNSIGNED NOT NULL default 0,
                        ARGUMENTS   BLOB,
                        STATUS      TINYINT UNSIGNED NOT NULL default 0, -- this is the jobstatus
                        STDOUT      BLOB,
                        STDERR      BLOB,
                        EXITCODE    INTEGER,   -- exitcode of the commands on the client side
                        CREATED     TIMESTAMP default CURRENT_TIMESTAMP,
                        TARGETED    TIMESTAMP NULL default NULL,
                        EXPIRES     TIMESTAMP NULL default NULL,
                        RETRIEVED   TIMESTAMP NULL default NULL,
                        FINISHED    TIMESTAMP NULL default NULL,
                        PERSISTENT  TINYINT(1) NOT NULL default 0,
                        VERBOSE     TINYINT(1) NOT NULL default 0,
                        TIMELAG     TIME NULL default NULL,
                        PRIMARY KEY (ID, GUID_ID)
                      );
