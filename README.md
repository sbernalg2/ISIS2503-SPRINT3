# OptiCloud: AWS infrastructure as code

Course project for Arquitectura y Diseño de Software (Universidad de los Andes). It deploys a Django application on AWS using Terraform and was used to validate availability and security requirements with experiments and JMeter load tests.

## What `main.tf` creates

- An Application Load Balancer in front of an Auto Scaling Group of 3 to 6 `t3.micro` instances. CloudWatch alarms add instances when CPU goes above 60% and remove them below 30%.
- A private PostgreSQL 16 database on RDS, reachable only from the web servers.
- An S3 bucket with the setup script for the web servers, and an IAM role that only lets them read that bucket.
- Separate security groups for the load balancer, web servers, database and an auxiliary server.

`scripts/setup_webserver.sh` is passed through `templatefile()` so the RDS credentials are filled in before the instance boots. It installs Django and Gunicorn and logs to `/var/log/opticloud-setup.log`.

## Requirements validated

| Requirement | Target | Endpoint |
|---|---|---|
| Failure detection | ≤ 200 ms | `GET /worker/status/?fail=1` |
| Recovery | ≤ 2000 ms | `POST /worker/recover/` |
| Anomalous request detection | ≤ 200 ms | `GET /security/check/` |
| IP blocking | immediate | `POST /security/block/` |

## Deploying

```bash
terraform init
terraform apply -var="db_username=..." -var="db_password=..." -var="ami_id=..."
```

After `apply`, Terraform prints the load balancer DNS name, the RDS endpoint and the commands for the experiments. Run `terraform destroy` afterwards to avoid AWS charges.
