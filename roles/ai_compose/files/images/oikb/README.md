Notes:

Must first build custom container using `oikb.dockerfile`:

```sh
docker build -t oikb:latest -f ./oikb.dockerfile .
```

This step is required for `docker-compose.yaml` to work as written. It is necessary to 
address a bug in the oikb code where it expects a now-deprecated response schema from 
Open WebUI. See [this issue](https://github.com/open-webui/oikb/issues/10) for details.

Additional configuration requirements:

Needs authentication environment variables for datasources, e.g. for Gitlab, both 
GITLAB_URL and GITLAB_TOKEN are required. The OPEN_WEBUI_URL and OPEN_WEBUI variables 
also need to be set up and configured appropriately. 

A .oikb.yaml file also needs to be created to link data sources and knowledge bases 
configured in Open WebUI. 