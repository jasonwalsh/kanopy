output "instance_id" {
  description = "The instance's ID."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "The Elastic IP address."
  value       = aws_eip.this.public_ip
}
