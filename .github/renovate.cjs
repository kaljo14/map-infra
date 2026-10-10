// Bot credentials are supplied by GitHub Actions, never stored in Git.
module.exports = {
  platform: 'github',
  autodiscover: true,
  autodiscoverFilter: [
    'kaljo14/map-infra',
    'kaljo14/my-map',
    'kaljo14/geoapi',
  ],
  onboarding: true,
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
