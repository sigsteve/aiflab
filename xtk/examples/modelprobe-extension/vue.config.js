const path = require('node:path');

const config = require('./.shell/pkg/vue.config')(__dirname);
const configureWebpack = config.configureWebpack;

config.configureWebpack = (webpackConfig) => {
  configureWebpack(webpackConfig);
  webpackConfig.resolve.alias['@aif-xtk/sdk'] = path.resolve(
    __dirname,
    '../../packages/sdk/src/index.ts',
  );
};

module.exports = config;
