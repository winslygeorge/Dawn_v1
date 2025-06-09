-- orm/init.lua

--- This is the main entry point for the LuaJIT ORM.
--- It exposes the core components, primarily the Model base class,
--- allowing users to define and interact with their database models.

local ORM = {}

--- The base Model class from which all application-specific models should extend.
--- @type table
ORM.Model = require("db.orm.model")

--- The SchemaManager for DDL operations (CREATE TABLE, DROP TABLE, etc.).
--- @type table
ORM.Schema = require("db.orm.schema_manager")

--- The ModelRoute class for generating RESTful API routes based on ORM models.
--- @type table
ORM.ModelRoute = require("db.orm.model_route")

--- (Optional) Expose configuration for direct access if needed, though typically
--- models will use the config internally.
--- @type table
ORM.config = require("db.orm.config")

--- (Optional) Expose connection manager for advanced use cases.
--- @type table
ORM.ConnectionManager = require("db.orm.connection_manager")

--- (Optional) Expose query builder for advanced use cases.
--- @type table
ORM.QueryBuilder = require("db.orm.query_builder")

--- (Optional) Expose result mapper for advanced use cases.
--- @type table
ORM.ResultMapper = require("db.orm.result_mapper")

return ORM
