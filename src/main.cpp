#include <Tensor/Grid.h>
#include <Image/System.h>
#include <Parallel/Parallel.h>
#include <Common/Exception.h>
#include <chrono>
#include <map>
	
typedef ::Tensor::Grid<int, 2> Grid;
typedef ::Tensor::Vector<int, 2> vec2i;
typedef ::Tensor::Vector<unsigned char, 3> Color;

int main(int argc, char** argv) {	
	::Parallel::Parallel parallel(4);

	int modulo = 4;
	int initialstack = 1<<10;
	vec2i size(1001, 1001);
	
	if (argc > 1) {
		initialstack = atoi(argv[1]);
	}
	if (argc > 2) {
		size(0) = size(1) = atoi(argv[2]);
	}

	std::vector<Color> colors = {
		Color(0,0,0),
		Color(0,255,255),
		Color(255,255,0),
		Color(255,0,0),
	};
	if ((int)colors.size() < modulo) throw Common::Exception() << "not enough colors";

	Grid topple(size);


	struct compare {
		bool operator()(const vec2i& a, const vec2i& b) {
			if (a(0) == b(0)) return a(1) < b(1);
			return a(0) < b(0);
		}
	};


	std::map<vec2i, bool, compare> dirty;

	//place it in the middle
	vec2i place = size/2;
	topple(place) = initialstack;
	dirty[place] = true;

	std::vector<vec2i> edges = {
		vec2i(-1,0),
		vec2i(1,0),
		vec2i(0,-1),
		vec2i(0,1),
	};

	typedef std::chrono::high_resolution_clock Clock;
	//recurse until we're done
	int iteration = 0;
	auto startTime = Clock::now();
	while (!dirty.empty()) {
			
		std::map<vec2i, bool>::iterator iter = dirty.begin();
		vec2i i = iter->first;
		dirty.erase(iter);
	
		int stacksize = topple(i);

		int whatsleft = stacksize % modulo;
		int nbhsget = (stacksize - whatsleft) / modulo;
		topple(i) = whatsleft;
		++iteration;

		for (vec2i edge : edges) {
			vec2i n = i + edge;
			if (n(0) < 0 || n(1) < 0 || n(0) >= size(0) || n(1) >= size(1)) continue;
			int& neighbor = topple(n);
			neighbor += nbhsget;
			if (neighbor >= modulo) {
				dirty[n] = true;
			}
		}
	}
	auto endTime = Clock::now();
	std::chrono::duration<double, std::milli> milliseconds = endTime - startTime;
	std::cout << (milliseconds.count() / 1000.) << " seconds" << std::endl;
	std::cout << iteration << " iterations" << std::endl;

	std::shared_ptr<Image::Image> image = std::make_shared<Image::Image>(size);
	parallel.foreach(topple.range().begin(), topple.range().end(), [&](vec2i i) {
		int amt = topple(i);
		Color color = colors[amt];
		for (int ch = 0; ch < 3; ++ch) {
			(*image)(i(0), i(1), ch) = color(ch);
		}
	});

	Image::system->write("output.cpu.png", image);
}
