
drop table if exists Catalogs;
drop table if exists Products;
drop table if exists ProductCatalogs;
drop table if exists Registration;
drop table if exists MachineData;
drop table if exists Targets;
drop table if exists Clients;

drop table if exists Subscriptions;
drop table if exists ClientSubscriptions;

drop table if exists RepositoryContentData;


create table Clients(GUID        CHAR(50) PRIMARY KEY,
                     HOSTNAME    VARCHAR(100) DEFAULT '',
                     TARGET      VARCHAR(100),
                     DESCRIPTION VARCHAR(500) DEFAULT '',
                     LASTCONTACT TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                     NAMESPACE   VARCHAR(300) NOT NULL DEFAULT '',
                     SECRET      CHAR(50) NOT NULL DEFAULT ''
                    );


create table Subscriptions(SUBID          CHAR(50) PRIMARY KEY, 
                           REGCODE        VARCHAR(100),
                           SUBNAME        VARCHAR(100) NOT NULL,
                           SUBTYPE        CHAR(20)  DEFAULT "UNKNOWN",
                           SUBSTATUS      CHAR(20)  DEFAULT "UNKNOWN",
                           SUBSTARTDATE   TIMESTAMP NULL default NULL,
                           SUBENDDATE     TIMESTAMP NULL default CURRENT_TIMESTAMP,
                           SUBDURATION    BIGINT    DEFAULT 0,
                           SERVERCLASS    CHAR(50),
                           PRODUCT_CLASS  VARCHAR(100),
                           NODECOUNT      integer NOT NULL,
                           CONSUMED       integer DEFAULT 0,
                           CONSUMEDVIRT   integer DEFAULT 0,
                           INDEX idx_sub_product_class (PRODUCT_CLASS)
                          );

create table ClientSubscriptions(GUID    CHAR(50) NOT NULL,
                                 SUBID   CHAR(50) NOT NULL,
                                 PRIMARY KEY(GUID, SUBID)
                                );

create table Registration(GUID         CHAR(50) NOT NULL,
                          PRODUCTID    integer NOT NULL,
                          REGDATE      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                          NCCREGDATE   TIMESTAMP NULL default NULL,
                          NCCREGERROR  integer DEFAULT 0,
                          PRIMARY KEY(GUID, PRODUCTID)
                       -- FOREIGN KEY (ProductID) REFERENCES Products  -- FOREIGN KEY not supported by sqlite3
                         );

create table MachineData(GUID          CHAR(50) NOT NULL,
                         KEYNAME       CHAR(50) NOT NULL,
                         VALUE         BLOB,
                         PRIMARY KEY(GUID, KEYNAME)
                      -- FOREIGN KEY (GUID) REFERENCES Registration (GUID) ON DELETE CASCADE -- FOREIGN KEY not supported by sqlite3
                        );

-- used for NU catalogs and single RPMMD sources
create table Catalogs(CATALOGID   CHAR(50) PRIMARY KEY, 
                      NAME        VARCHAR(200) NOT NULL, 
                      DESCRIPTION VARCHAR(500), 
                      TARGET      VARCHAR(100),           -- null in case of single RPMMD source
                      LOCALPATH   VARCHAR(300) NOT NULL,
                      EXTHOST     VARCHAR(300) NOT NULL,  
                      EXTURL      VARCHAR(300) NOT NULL,  -- where to mirror from
                      CATALOGTYPE CHAR(10) NOT NULL,
                      DOMIRROR    CHAR(1) DEFAULT 'N',
                      MIRRORABLE  CHAR(1) DEFAULT 'N',
                      SRC         CHAR(1) DEFAULT 'N',    -- N NCC    C Custom
                      UNIQUE(NAME, TARGET)
                     );


-- copy of NNW_PRODUCT_DATA
create table Products (
                PRODUCTDATAID   integer NOT NULL PRIMARY KEY,
                PRODUCT         VARCHAR(500) NOT NULL,
                VERSION         VARCHAR(100),
                REL             VARCHAR(100),
                ARCH            VARCHAR(100),
                PRODUCTLOWER    VARCHAR(500) NOT NULL,
                VERSIONLOWER    VARCHAR(100),
                RELLOWER        VARCHAR(100),
                ARCHLOWER       VARCHAR(100),
                FRIENDLY        VARCHAR(700),
                PARAMLIST       TEXT,
                NEEDINFO        TEXT,
                SERVICE         TEXT,
                PRODUCT_LIST    CHAR(1),
                PRODUCT_CLASS   CHAR(50),
                SRC         CHAR(1) DEFAULT 'N',    -- N NCC   C Custom
                UNIQUE(PRODUCTLOWER, VERSIONLOWER, RELLOWER, ARCHLOWER),
                INDEX idx_prod_product_class (PRODUCT_CLASS)  
                );


create table ProductCatalogs(PRODUCTDATAID integer NOT NULL,
                             CATALOGID     CHAR(50) NOT NULL,
                             OPTIONAL      CHAR(1) DEFAULT 'N',
                             SRC         CHAR(1) DEFAULT 'N',    -- N NCC   C Custom
                             PRIMARY KEY(PRODUCTDATAID, CATALOGID)
                            );

create table Targets (OS      VARCHAR(200) NOT NULL PRIMARY KEY,
                      TARGET  VARCHAR(100) NOT NULL,
                      SRC         CHAR(1) DEFAULT 'N'    -- N NCC   C Custom
                     );

create table RepositoryContentData(localpath   VARCHAR(300) PRIMARY KEY,
                                   name        VARCHAR(300) NOT NULL,
                                   checksum    CHAR(50)     NOT NULL,
                                   INDEX idx_repo_cont_data_name_checksum (name, checksum)
                                  );
-- end


