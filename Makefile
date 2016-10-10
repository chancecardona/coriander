# In theory we should use eg cmake, but this gives us more control for now,
# and we only have like ~4 sourcecode files for now anyway

CUDA_HOME=/usr/local/cuda-7.5
EIGEN_HOME=/usr/local/eigen

CLANG=clang++-3.8
LLVM_CONFIG=llvm-config-3.8
LLVM_INCLUDE=/usr/include/llvm-3.8

# COMPILE_FLAGS=`$(LLVM_CONFIG) --cxxflags` -std=c++11
LINK_FLAGS=`$(LLVM_CONFIG) --ldflags --system-libs --libs all`
# the llvm-config compile flags suppresses asserts
COMPILE_FLAGS=-I/usr/lib/llvm-3.8/include -fPIC -fvisibility-inlines-hidden -ffunction-sections -fdata-sections -O2 -g -D_GNU_SOURCE -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS -std=c++11

all: build/ir-to-opencl build/patch-hostside build/hostside_opencl_funcs.o

build/ir-to-opencl: src/ir-to-opencl.cpp src/ir-to-opencl-common.cpp src/ir-to-opencl-common.h
	mkdir -p build
	$(CLANG) $(COMPILE_FLAGS) -fcxx-exceptions -o build/ir-to-opencl -g -O3 -I$(LLVM_INCLUDE) src/ir-to-opencl.cpp src/ir-to-opencl-common.cpp $(LINK_FLAGS)

build/patch-hostside: src/patch-hostside.cpp src/ir-to-opencl-common.cpp src/ir-to-opencl-common.h
	mkdir -p build
	$(CLANG) $(COMPILE_FLAGS) -fcxx-exceptions -o build/patch-hostside -g -O3 -I$(LLVM_INCLUDE) src/patch-hostside.cpp src/ir-to-opencl-common.cpp $(LINK_FLAGS)

easycl:
	git submodule update --init --recursive
	cd build && cmake ../src/EasyCL -DCMAKE_INSTALL_PREFIX=`pwd`/dist -DBUILD_TESTS=ON
	cd build && make -j 4

clean:
	rm -Rf build/* test/generated/*

# IR

# deviceside goes directly from .cu => -device.ll

test/generated/%-device.ll: test/%.cu include/fake_funcs.h build/ir-to-opencl
	echo building $@ from $<
	mkdir -p test/generated
	$(CLANG) -include include/fake_funcs.h -I$(CUDA_HOME)/include $< --cuda-device-only -emit-llvm -O3 -S -o $@

test/eigen/generated/%-device.ll: test/eigen/%.cu include/fake_funcs.h build/ir-to-opencl
	echo building $@ from $<
	mkdir -p test/eigen/generated
	$(CLANG) -x cuda -std=c++11 -DEIGEN_TEST_FUNC=cuda_elementwise_small -D__CUDA_ARCH__=300 -include include/fake_funcs.h -Iinclude -I$(EIGEN_HOME) -I$(CUDA_HOME)/include -I/usr/include/x86_64-linux-gnu $< --cuda-device-only -emit-llvm -O3 -S -o $@

# hostside goes from .cu -> -hostraw.ll

test/generated/%-hostraw.ll: test/%.cu
	echo building $@ from $< using $(CLANG) CUDA_HOME $(CUDA_HOME)
	mkdir -p test/generated
	$(CLANG) -I$(CUDA_HOME)/include $< --cuda-host-only -emit-llvm  -O3 -S -o $@

test/eigen/generated/%-hostraw.ll: test/eigen/%.cu include/fake_funcs.h
	echo building $@ from $<
	mkdir -p test/eigen/generated
	$(CLANG) -std=c++11 -include include/fake_funcs.h -I$(EIGEN_HOME) -I$(CUDA_HOME)/include $< --cuda-host-only -emit-llvm  -O3 -S -o $@

# .hostraw.ll => .hostpatched.ll

test/generated/%-hostpatched.ll: test/generated/%-hostraw.ll test/generated/%-device.cl build/patch-hostside
	echo building $@ from $<
	build/patch-hostside $< $(word 2,$^) $@

test/eigen/generated/%-hostpatched.ll: test/eigen/generated/%-hostraw.ll test/eigen/generated/%-device.cl build/patch-hostside
	echo building $@ from $<
	build/patch-hostside $< $(word 2,$^) $@

test/eigen/generated/%-hostpatched.ll-lldb: test/eigen/generated/%-hostraw.ll test/eigen/generated/%-device.cl build/patch-hostside
	echo building $@ from $<
	lldb-3.8 build/patch-hostside $< $(word 2,$^) $@

# opencl (from the -device.ll)

%-device.cl: %-device.ll build/ir-to-opencl
	echo building $@ from $<
	build/ir-to-opencl $(DEBUG) $< $@

tensorflow/generated/%.cl: tensorflow/generated/%.ll build/ir-to-opencl
	echo building $@ from $<
	build/ir-to-opencl $(DEBUG) $< $@

test/generated/%-device.cl: test/%-device.ll build/ir-to-opencl
	echo building $@ from $<
	build/ir-to-opencl $(DEBUG) $< $@

%-device.cl-lldb: %-device.ll build/ir-to-opencl
	echo building $@ from $<
	lldb-3.8 build/ir-to-opencl $(DEBUG) $< $@

# objects

## objects from hostside patched ll

build/%-hostpatched.o: test/generated/%-hostpatched.ll
	echo building $@ from $<
	$(CLANG) -c $< -O3 -o $@

build/eigen-%-hostpatched.o: test/eigen/generated/%-hostpatched.ll
	echo building $@ from $<
	$(CLANG) -c $< -O3 -o $@

## generic cpp objects, from cpp code

build/test_call_cl.o: test/test_call_cl.cpp easycl
	echo building $@ from $<
	$(CLANG) -std=c++11 -Isrc/EasyCL -I$(CUDA_HOME)/include -c $< --cuda-host-only -O3 -o $@

build/%.o: test/%.cpp easycl
	echo building $@ from $<
	$(CLANG) -std=c++11 -Isrc/EasyCL -c $< --cuda-host-only -O3 -o $@

build/hostside_opencl_funcs.o: src/hostside_opencl_funcs.cpp easycl
	echo building $@ from $<
	$(CLANG) -std=c++11 -Isrc/EasyCL -c $< -O3 -o $@

# executables
build/test_call_cl: build/test_call_cl.o build/testcudakernel1-hostpatched.o build/hostside_opencl_funcs.o test/generated/testcudakernel1-device.cl
	g++ -o build/test_call_cl build/test_call_cl.o build/hostside_opencl_funcs.o build/testcudakernel1-hostpatched.o -lOpenCL -Lbuild -lEasyCL

build/cuda_sample: build/cuda_sample-hostpatched.o build/hostside_opencl_funcs.o test/generated/cuda_sample-device.cl
	g++ -o build/cuda_sample build/hostside_opencl_funcs.o build/cuda_sample-hostpatched.o -lOpenCL -Lbuild -lEasyCL

build/eigen-%i: build/eigen-%i-hostpatched.o build/hostside_opencl_funcs.o test/eigen/generated/%i-device.cl
	g++ -o $@ $< build/hostside_opencl_funcs.o -lOpenCL -Lbuild -lEasyCL

# build/test_cuda_elementwise_small: build/eigen-test_cuda_elementwise_small-hostpatched.o build/hostside_opencl_funcs.o test/generated/test_cuda_elementwise_small-device.cl
# 	g++ -o $@ $< build/hostside_opencl_funcs.o -lOpenCL -Lbuild -lEasyCL

# build/eigen-test_cuda_nullary: build/eigen-test_cuda_nullary-hostpatched.o build/hostside_opencl_funcs.o test/eigen/generated/test_cuda_nullary-device.cl
# 	g++ -o $@ $< build/hostside_opencl_funcs.o -lOpenCL -Lbuild -lEasyCL

# build/eigen-test_cuda_elementwise: build/eigen-test_cuda_elementwise-hostpatched.o build/hostside_opencl_funcs.o test/eigen/generated/test_cuda_elementwise-device.cl
# 	g++ -o $@ $< build/hostside_opencl_funcs.o -lOpenCL -Lbuild -lEasyCL

run-cuda_sample: build/cuda_sample
	################################
	# running:
	################################
	LD_LIBRARY_PATH=build:$(LD_LIBRARY_PATH) build/cuda_sample

run-test_cuda_elementwise_small: build/test_cuda_elementwise_small
	################################
	# running:
	################################
	LD_LIBRARY_PATH=build:$(LD_LIBRARY_PATH) build/test_cuda_elementwise_small

run-eigen-test_cuda_nullary: build/eigen-test_cuda_nullary
	################################
	# running:
	################################
	LD_LIBRARY_PATH=build:$(LD_LIBRARY_PATH) build/eigen-test_cuda_nullary

run-eigen-test_cuda_elementwise: build/eigen-test_cuda_elementwise
	################################
	# running:
	################################
	LD_LIBRARY_PATH=build:$(LD_LIBRARY_PATH) build/eigen-test_cuda_elementwise

.SECONDARY:
