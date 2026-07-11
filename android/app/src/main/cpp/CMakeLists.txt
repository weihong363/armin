cmake_minimum_required(VERSION 3.22.1)

project(armin_native_slm)

set(ARMIN_LLAMA_CPP_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/llama.cpp"
    CACHE PATH "Path to llama.cpp checkout")

add_library(armin_llama_jni SHARED armin_llama_jni.cpp)

target_compile_features(armin_llama_jni PRIVATE cxx_std_17)
target_link_libraries(armin_llama_jni android log)

if(EXISTS "${ARMIN_LLAMA_CPP_DIR}/include/llama.h")
    set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
    set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
    set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)

    target_compile_definitions(armin_llama_jni PRIVATE ARMIN_LLAMA_GENERATE_READY=1)
    target_include_directories(armin_llama_jni PRIVATE
        "${ARMIN_LLAMA_CPP_DIR}/include"
        "${ARMIN_LLAMA_CPP_DIR}/ggml/include"
    )

    if(TARGET llama)
        target_link_libraries(armin_llama_jni llama)
    elseif(EXISTS "${ARMIN_LLAMA_CPP_DIR}/CMakeLists.txt")
        add_subdirectory("${ARMIN_LLAMA_CPP_DIR}" "${CMAKE_BINARY_DIR}/llama.cpp")
        target_link_libraries(armin_llama_jni llama)
    endif()
else()
    message(STATUS "llama.cpp not found at ${ARMIN_LLAMA_CPP_DIR}; building unavailable native SLM stub.")
endif()
