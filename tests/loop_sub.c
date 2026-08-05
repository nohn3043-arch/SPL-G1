// Test: loop counter — compile with splcc v0.1
int main() {
    int counter = 5;
    for (int i = 0; i < 5; i = i + 1) {
        counter = counter - 1;
    }
    return counter;
}
