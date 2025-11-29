variable "region" { type = string, default = "us-east-1" }
variable "lambda_name" { type = string, default = "modulo03-stats-lambda" }
variable "visits_table_name" { type = string, default = "visits" }
variable "users_table_name" { type = string, default = "users" }
variable "lambda_handler" { type = string, default = "index.handler" }
variable "stage" { type = string, default = "prod" }