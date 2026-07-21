import json
import hmac
import hashlib
import os
import boto3

secretsmanager = boto3.client('secretsmanager')
codepipeline = boto3.client('codepipeline')

SECRET_ARN = os.environ['WEBHOOK_SECRET_ARN']
PIPELINE_NAME = os.environ['PIPELINE_NAME']

def get_webhook_secret() -> str:
    response = secretsmanager.get_secret_value(SecretId=SECRET_ARN)
    return response['SecretString']

def verify_signature(payload_body: bytes, signature_header: str, secret: str) -> bool:
    """Verify GitHub's HMAC-SHA256 signature using constant-time comparison."""
    if not signature_header or not signature_header.startswith('sha256='):
        return False

    expected_signature = hmac.new(
        key=secret.encode('utf-8'),
        msg=payload_body,
        digestmod=hashlib.sha256
    ).hexdigest()

    received_signature = signature_header.removeprefix('sha256=')

    # hmac.compare_digest prevents timing attacks 
    return hmac.compare_digest(expected_signature, received_signature)

def lambda_handler(event, context):
    headers = event.get('headers', {})
    signature_header = headers.get('x-hub-signature-256') or headers.get('X-Hub-Signature-256')
    payload_body = event.get('body', '')

    if event.get('isBase64Encoded'):
        import base64
        payload_body = base64.b64decode(payload_body)
    else:
        payload_body = payload_body.encode('utf-8')

    secret = get_webhook_secret()

    if not verify_signature(payload_body, signature_header, secret):
        return {
            'statusCode': 401,
            'body': json.dumps({'error': 'Invalid signature'})
        }

    payload = json.loads(payload_body)

    # Only trigger on pushes to main, not every GitHub event type
    github_event = headers.get('x-github-event') or headers.get('X-GitHub-Event')
    if github_event != 'push':
        return {'statusCode': 200, 'body': json.dumps({'message': 'Event ignored'})}

    if payload.get('ref') != 'refs/heads/main':
        return {'statusCode': 200, 'body': json.dumps({'message': 'Branch ignored'})}

    response = codepipeline.start_pipeline_execution(name=PIPELINE_NAME)

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Pipeline triggered',
            'executionId': response['pipelineExecutionId']
        })
    }