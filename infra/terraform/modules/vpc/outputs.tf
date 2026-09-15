output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
output "public_subnet_ids" { value = [for s in aws_subnet.public : s.id] }
output "app_subnet_ids" { value = [for s in aws_subnet.app : s.id] }
output "data_subnet_ids" { value = [for s in aws_subnet.data : s.id] }
output "azs" { value = local.azs }
