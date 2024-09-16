// TTSManager.js

import { NativeModules, NativeEventEmitter } from 'react-native';

const { TTSManager } = NativeModules;
const ttsManagerEmitter = new NativeEventEmitter(TTSManager);

const initialize = (sampleRate: any, channels: any) => {
  TTSManager.initializeWithSampleRate(sampleRate, channels);
};

const generateAndPlay = async (text: any, sid: any, speed: any) => {
  try {
    const result = await TTSManager.generateAndPlay(text, sid, speed);
    console.log(result);
  } catch (error) {
    console.error(error);
  }
};

const deinitialize = () => {
  TTSManager.deinitialize();
};

const addVolumeListener = (callback: any) => {
  const subscription = ttsManagerEmitter.addListener(
    'VolumeUpdate',
    (event) => {
      const { volume } = event;
      callback(volume);
    }
  );
  return subscription;
};

export default {
  initialize,
  generateAndPlay,
  deinitialize,
  addVolumeListener,
};
