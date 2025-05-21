#include <uWebSockets/App.h>
#include <iostream>

int main() {
    std::cout << "uWebSockets Version: " << UWS_VERSION_MAJOR << "." 
              << UWS_VERSION_MINOR << "." 
              << UWS_VERSION_PATCH << std::endl;
    return 0;
}
