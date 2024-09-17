const https = require('https');
const fs = require('fs');
const path = require('path');
const bz2 = require('unbzip2-stream'); // Module to handle bz2 decompression
const tar = require('tar'); // Native tar module to handle extraction

const url =
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.10.26/sherpa-onnx-v1.10.26-ios.tar.bz2';
const destination = path.join(__dirname, 'sherpa-onnx-v1.10.26-ios.tar.bz2');
const tarFilePath = path.join(__dirname, 'sherpa-onnx-v1.10.26-ios.tar'); // Temporary path for the decompressed tar file
const extractPath = path.join(__dirname, '..');

function downloadFile(url, destination, callback) {
  https
    .get(url, (response) => {
      // Handle redirects
      if (
        response.statusCode >= 300 &&
        response.statusCode < 400 &&
        response.headers.location
      ) {
        return downloadFile(response.headers.location, destination, callback);
      }

      const file = fs.createWriteStream(destination);
      response.pipe(file);

      file.on('finish', () => {
        file.close(callback);
      });

      file.on('error', (err) => {
        fs.unlink(destination, () => {}); // Cleanup if error
        console.error('Error writing to file:', err.message);
      });
    })
    .on('error', (err) => {
      console.error('Download failed:', err.message);
    });
}

downloadFile(url, destination, () => {
  // Step 1: Decompress the .bz2 file to .tar
  const input = fs.createReadStream(destination);
  const output = fs.createWriteStream(tarFilePath);

  input
    .pipe(bz2())
    .pipe(output)
    .on('finish', async () => {
      try {
        // Step 2: Extract the .tar file
        await tar.x({
          file: tarFilePath,
          cwd: extractPath,
          sync: true, // Extract synchronously
        });

        // Cleanup the tar.bz2 and .tar files after extraction
        fs.unlinkSync(destination);
        fs.unlinkSync(tarFilePath);

        console.log(
          'sherpa-onnx-v1.10.26-ios downloaded, decompressed, and extracted.'
        );

        // Verification: Check if 'build-ios' directory exists
        const buildIosPath = path.join(extractPath, 'build-ios');
        if (fs.existsSync(buildIosPath)) {
          console.log('Verification successful: build-ios directory exists.');
          fs.readdir(buildIosPath, (err, files) => {
            if (err) {
              console.error('Error reading build-ios directory:', err);
            } else {
              console.log('Contents of build-ios:', files);
            }
          });
        } else {
          console.error('Verification failed: build-ios directory is missing.');
        }
      } catch (error) {
        console.error('Error during extraction:', error);
      }
    })
    .on('error', (error) => {
      console.error('Error during decompression:', error);
    });
});
