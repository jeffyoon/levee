brew install cmake
brew install ragel
cmake -H. -Bbuild -DCMAKE_BUILD_TYPE=Debug
cd build && make && sudo make install && cd ..

