// TTSManager.js

import { NativeModules, NativeEventEmitter } from 'react-native';

const { TTSManager } = NativeModules;
const ttsManagerEmitter = new NativeEventEmitter(TTSManager);

const initialize = (modelId: string) => {
  TTSManager.initializeTTS(22050, 1, modelId);
};

const generate = async (text: any, sid: any, speed: any) => {
  try {
    const result = await TTSManager.generate(text, sid, speed);
    console.log(result);
    return result;
  } catch (error) {
    console.error(error);
    throw error;
  }
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

const addAudioChunkListener = (callback: any) => {
  const subscription = ttsManagerEmitter.addListener(
    'AudioChunkGenerated',
    (event) => {
      const { chunk, index, total, sampleRate } = event;
      callback({ chunk, index, total, sampleRate });
    }
  );
  return subscription;
};

export default {
  initialize,
  generate,
  generateAndPlay,
  deinitialize,
  addVolumeListener,
  addAudioChunkListener,
};
