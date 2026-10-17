# Create the main VPC for our DevSecOps lab.
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "platform-devsecops-vpc"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "platform-devsecops-public-subnet"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "platform-devsecops-igw"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "platform-devsecops-public-rt"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
# Create a private subnet for internal resources.
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.2.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name        = "platform-devsecops-private-subnet"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
# Create a dedicated route table for the private subnet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "platform-devsecops-private-rt"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
# Associate the private subnet with its dedicated route table.
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
# Create a security group for future web servers.
resource "aws_security_group" "web" {
  name        = "platform-devsecops-web-sg"
  description = "Security group for public web servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow public HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "platform-devsecops-web-sg"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
# Create a security group for future private resources.
resource "aws_security_group" "private" {
  name        = "platform-devsecops-private-sg"
  description = "Security group for private resources"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "platform-devsecops-private-sg"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}
# Allow the web tier to reach the private tier on TCP port 8080.
resource "aws_vpc_security_group_ingress_rule" "private_from_web" {
  security_group_id            = aws_security_group.private.id
  referenced_security_group_id = aws_security_group.web.id

  ip_protocol = "tcp"
  from_port   = 8080
  to_port     = 8080

  description = "Allow application traffic from the web security group"
}
# Create a security group for the database tier.
resource "aws_security_group" "database" {
  name        = "platform-devsecops-database-sg"
  description = "Security group for private database resources"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name        = "platform-devsecops-database-sg"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}

# Allow PostgreSQL traffic from the private application tier.
resource "aws_vpc_security_group_ingress_rule" "database_from_private" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.private.id

  ip_protocol = "tcp"
  from_port   = 5432
  to_port     = 5432

  description = "Allow PostgreSQL traffic from the private application tier"
} # Allow the web tier to send HTTP application traffic to the private tier.
resource "aws_vpc_security_group_egress_rule" "web_to_private" {
  security_group_id            = aws_security_group.web.id
  referenced_security_group_id = aws_security_group.private.id

  ip_protocol = "tcp"
  from_port   = 8080
  to_port     = 8080

  description = "Allow web tier outbound traffic to the application tier"
}

# Allow the application tier to connect to PostgreSQL.
resource "aws_vpc_security_group_egress_rule" "private_to_database" {
  security_group_id            = aws_security_group.private.id
  referenced_security_group_id = aws_security_group.database.id

  ip_protocol = "tcp"
  from_port   = 5432
  to_port     = 5432

  description = "Allow application tier outbound traffic to PostgreSQL"
}