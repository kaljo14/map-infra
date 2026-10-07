// Bot credentials are supplied by GitHub Actions, never stored in Git.
module.exports = {
  platform: 'github',
  repositories: [process.env.GITHUB_REPOSITORY],
  onboarding: false,
  requireConfig: 'required',
  // The containerbase image can install Flux to update gotk-components.yaml.
  binarySource: 'install',
  hostRules: process.env.DOCKERHUB_USERNAME && process.env.DOCKERHUB_TOKEN
    ? [{
        hostType: 'docker',
        matchHost: 'https://index.docker.io',
        username: process.env.DOCKERHUB_USERNAME,
        password: process.env.DOCKERHUB_TOKEN,
      }]
    : [],
};
