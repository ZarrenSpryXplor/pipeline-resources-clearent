import * as core from '@actions/core';
import {HttpClient} from '@actions/http-client';

process.on('unhandledRejection', handleError);
main().catch(handleError);

function sleep(sec: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, sec * 1000));
}

interface RancherStack {
  id: string;
}

interface RancherLaunchConfig {
  imageUuid?: string;
  [key: string]: unknown;
}

interface RancherService {
  id: string;
  launchConfig: RancherLaunchConfig;
}

interface RancherListResponse<T> {
  data?: T[];
}

interface RancherServiceState {
  state?: string;
}

function parseInteger(value: string, name: string, minimum: number): number {
  const parsed = Number.parseInt(value, 10);

  if (!Number.isInteger(parsed) || parsed < minimum) {
    throw new Error(`Invalid ${name} input: expected an integer greater than or equal to ${minimum}, received "${value}".`);
  }

  return parsed;
}

function getFirstResult<T>(response: RancherListResponse<T> | undefined, resourceName: string): T {
  const item = response?.data?.[0];

  if (!item) {
    throw new Error(`Could not find ${resourceName}. Check the related input value and try again.`);
  }

  return item;
}

function formatError(err: unknown): string {
  if (err instanceof Error) {
    return err.stack ?? err.message;
  }

  return typeof err === 'string' ? err : String(err);
}

async function waitForState(
  waitFor: string,
  http: HttpClient,
  baseUrl: string,
  id: string,
  retryCount: number,
  retryDelay: number,
): Promise<void> {
  for (let attempt = 1; attempt <= retryCount; attempt++) {
    const state = (await http.getJson<RancherServiceState>(`${baseUrl}/services/${id}`))?.result?.state;

    core.info(`Service ${id}: attempt ${attempt}/${retryCount}, current state: ${state ?? 'unknown'}, waiting for: ${waitFor}`);

    if (state === waitFor) {
      return;
    }

    if (attempt < retryCount) {
      await sleep(retryDelay);
    }
  }

  throw new Error(`Maximum retries exceeded while waiting for service ${id} to reach state ${waitFor}.`);
}

async function main() {
  const RANCHER_URL = core.getInput('rancher_url', {required: true});
  const RANCHER_ACCESS = core.getInput('rancher_access', {required: true});
  const RANCHER_KEY = core.getInput('rancher_key', {required: true});
  const PROJECT_ID = core.getInput('project_id', {required: true});
  const STACK_NAME = core.getInput('stack_name', {required: true});
  const SERVICE_NAME = core.getInput('service_name', {required: true});
  const DOCKER_IMAGE = core.getInput('docker_image', {required: true});
  const RETRY_COUNT = parseInteger(core.getInput('retry_count', {required: true}), 'retry_count', 1);
  const RETRY_DELAY = parseInteger(core.getInput('retry_delay', {required: true}), 'retry_delay', 0);

  const http = new HttpClient('actions-rancher-deploy', undefined, {
    headers: {
      Authorization: `Basic ${Buffer.from(`${RANCHER_ACCESS}:${RANCHER_KEY}`).toString('base64')}`,
      'User-Agent': 'github-actions-rancher-deploy',
    },
  });
  const baseUrl = `${RANCHER_URL}/v2-beta/projects/${PROJECT_ID}`;

  core.startGroup('Rancher deployment request');
  core.info(`Project: ${PROJECT_ID}`);
  core.info(`Stack: ${STACK_NAME}`);
  core.info(`Service: ${SERVICE_NAME}`);
  core.info(`Target image: ${DOCKER_IMAGE}`);
  core.info(`Retry count: ${RETRY_COUNT}`);
  core.info(`Retry delay: ${RETRY_DELAY} seconds`);
  core.endGroup();

  let success = false;

  try {
    core.startGroup('Locate Rancher resources');
    const {result: stackResponse} = await http.getJson<RancherListResponse<RancherStack>>(
      `${baseUrl}/stacks?name=${encodeURIComponent(STACK_NAME)}`,
    );
    const stack = getFirstResult(stackResponse, `stack name "${STACK_NAME}"`);

    const {result: serviceResponse} = await http.getJson<RancherListResponse<RancherService>>(
      `${baseUrl}/services?name=${encodeURIComponent(SERVICE_NAME)}&stackId=${encodeURIComponent(stack.id)}`,
    );
    const service = getFirstResult(serviceResponse, `service name "${SERVICE_NAME}" in stack "${STACK_NAME}"`);
    core.info(`Resolved stack id: ${stack.id}`);
    core.info(`Resolved service id: ${service.id}`);
    core.endGroup();

    const desiredImageUuid = `docker:${DOCKER_IMAGE}`;
    const nextLaunchConfig = {
      ...service.launchConfig,
      imageUuid: desiredImageUuid,
    };

    if (service.launchConfig.imageUuid === desiredImageUuid) {
      core.info('Service already references the requested image. Continuing with upgrade to ensure the deployment is reconciled.');
    } else {
      core.info(`Updating service image from ${service.launchConfig.imageUuid ?? 'unknown'} to ${desiredImageUuid}.`);
    }

    core.startGroup('Start Rancher upgrade');
    await http.postJson(`${baseUrl}/service/${encodeURIComponent(service.id)}?action=upgrade`, {
      inServiceStrategy: {
        launchConfig: nextLaunchConfig,
      },
    });
    core.info('Upgrade request submitted. Waiting for Rancher to report upgraded state.');
    await waitForState('upgraded', http, baseUrl, service.id, RETRY_COUNT, RETRY_DELAY);

    core.info('Upgrade acknowledged. Finalizing upgrade and waiting for active state.');
    await http.post(`${baseUrl}/service/${encodeURIComponent(service.id)}?action=finishupgrade`, '');
    await waitForState('active', http, baseUrl, service.id, RETRY_COUNT, RETRY_DELAY);
    core.endGroup();

    success = true;
    core.setOutput('result', success);
    core.setOutput('stack_id', stack.id);
    core.setOutput('service_id', service.id);
    core.setOutput('image_uuid', desiredImageUuid);

    core.info('Service is running. Rancher upgrade completed successfully.');
  } finally {
    if (core.isDebug()) {
      core.debug(`Rancher deployment completed with success=${success}`);
    }
  }
}

function handleError(err: unknown) {
  core.error(formatError(err));
  core.setFailed(err instanceof Error ? err.message : 'Rancher deployment failed.');
}