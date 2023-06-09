import { Octokit as GitHubOctokit } from "@octokit/rest";
import { retry } from "@octokit/plugin-retry";
import { throttling } from "@octokit/plugin-throttling";

const Octokit = GitHubOctokit.plugin(retry, throttling);

export const newOctokitImpl = (authToken) => {
  const octokit = new Octokit({
    // If auth becomes necessary (for rate limiting, for example) then a GitHub
    // token can be passed as below:
    auth: authToken,
    request: {
      per_page: 100, // this is the maximum
    },
    throttle: {
      onRateLimit: (_, options) => {
        // Retry twice after hitting a rate limit error, then give up
        if (options.request.retryCount <= 2) {
          return true;
        }
      },
      onSecondaryRateLimit: () => {},
    },
  });
  return octokit;
};

export function requestImpl(octokit, route, headers, args, onError, onSuccess) {
  args["headers"] = headers;
  return octokit
    .request(route, args)
    .then((data) => onSuccess(data))
    .catch((err) => onError(err));
}

export function paginateImpl(
  octokit,
  route,
  headers,
  args,
  onError,
  onSuccess
) {
  args["headers"] = headers;
  return octokit
    .paginate(route, args)
    .then((data) => onSuccess(data))
    .catch((err) => onError(err));
}
