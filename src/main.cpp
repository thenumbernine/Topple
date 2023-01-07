#include <Tensor/Grid.h>
#include <Image/Image.h>
#include <Parallel/Parallel.h>
#include <Common/Exception.h>
#include <chrono>
#include <map>

using Grid = ::Tensor::Grid<int, 2>;
using vec2i = ::Tensor::int2;
using Color = ::Tensor::uchar3;
using Clock = std::chrono::high_resolution_clock;

std::vector<Color> colors = {
	Color(0,0,0),
	Color(0,255,255),
	Color(255,255,0),
	Color(255,0,0),
};

std::vector<vec2i> edges = {
	{-1,0},
	{1,0},
	{0,-1},
	{0,1},
};


//uses a single thread, only updates dirty cells
void test1(int modulo, int initialstack, vec2i size) {
	if ((int)colors.size() < modulo) throw Common::Exception() << "not enough colors";

	Grid topple(size);


	struct compare {
		bool operator()(vec2i const & a, vec2i const & b) const {
			if (a.x == b.x) return a.y < b.y;
			return a.x < b.x;
		}
	};
	std::map<vec2i, bool, compare> dirty;

	//place it in the middle
	vec2i place = size/2;
	topple(place) = initialstack;
	dirty[place] = true;

	//recurse until we're done
	int iteration = 0;
	auto startTime = Clock::now();
	int maxNbhdSize = 0;
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
			if (n.x < 0 || n.y < 0 || n.x >= size.x || n.y >= size.y) continue;
			int& neighbor = topple(n);
			neighbor += nbhsget;
			if (neighbor >= modulo) {
				dirty[n] = true;
			}
		}
		maxNbhdSize = std::max<int>(maxNbhdSize, dirty.size());
	}
	auto endTime = Clock::now();
	std::chrono::duration<double, std::milli> milliseconds = endTime - startTime;
	std::cout << (milliseconds.count() / 1000.) << " seconds" << std::endl;
	std::cout << iteration << " iterations" << std::endl;
	std::cout << maxNbhdSize << " max nbhd size" << std::endl;

	std::shared_ptr<Image::Image> image = std::make_shared<Image::Image>(size);
	::Parallel::Parallel parallel(4);
	parallel.foreach(topple.range().begin(), topple.range().end(), [&](vec2i i) {
		int amt = topple(i);
		Color color = colors[amt];
		for (int ch = 0; ch < 3; ++ch) {
			(*image)(i.x, i.y, ch) = color(ch);
		}
	});

	Image::system->write("output.cpu.png", image);
}

//only updates dirty cells, uses multiple threads
#if 0
void test2(int modulo, int initialstack, vec2i size) {
	::Parallel::Parallel parallel(4);
	if ((int)colors.size() < modulo) throw Common::Exception() << "not enough colors";

	struct Entry {
		vec2i pos;
		int amount;
		Entry() : amount(0) {}
		Entry(vec2i pos_, int amount_) : pos(pos_), amount(amount_) {}
	};


	//place it in the middle
	vec2i place = size/2;
	
	std::vector<Entry> entries;
	entries.push_back(Entry(place, initialstack));
	
	//map from thread ID to vector of new entries
	std::map<std::thread::id, std::vector<Entry>> nextEntriesForThread;

	//next iteration's entries (all nextEntriesForThread combined)
	std::vector<Entry> nextEntries;

	//recurse until we're done
	int iteration = 0;
	auto startTime = Clock::now();
	int maxNbhdSize = 0;
	for (;;) {
		//clear the new entries
		parallel.foreach(nextEntriesForThread.begin(), nextEntriesForThread.end(), [&](std::pair<int, std::vector<Entry>> &pair) {
			pair.second.resize(0);
		});
	
		//populate the new entries
		int moved = 0;
		parallel.foreach(entries.begin(), entries.end(), [&](Entry entry) {
			std::vector<Entry>& nextEntriesForThisThread = nextEntriesForThread[std::this_thread::get_id()];
			
			int stacksize = entry.amount;
			int whatsleft = stacksize % modulo;
			int nbhsget = (stacksize - whatsleft) / modulo;
			if (nbhsget > 0) {
				moved = 1;
				nextEntriesForThisThread.push_back(Entry(entry.pos, whatsleft));
				++iteration;
				for (vec2i edge : edges) {
					vec2i n = entry.pos + edge;
					if (n(0) < 0 || n(1) < 0 || n(0) >= size(0) || n(1) >= size(1)) continue;
					nextEntriesForThisThread.push_back(Entry(n, nbhsget));
				}
			}
		});

		//now we recombine all vectors
		//and then combine matching cells ...
		//but this can't be done in parallel can it?

		//another problem is leaving modulo entries in 'entries'
		//they are only left in for testing for collision
		//but otherwise they'll clog up the overflow pass - because they don't have any overflow

		entries.resize(0);
		parallel.foreach(nextEntriesForThread.begin(), nextEntriesForThread.end(), [&](std::pair<int, std::vector<Entry>> &pair) {
			entries.insert(nextEntries.end(), pair.second.begin(), pair.second.end());
		});
		
		if (!moved) break;
		
		std::sort(entries.begin(), entries.end(), [&](const Entry& a, const Entry& b) -> bool {
			return a.pos(0) + size(0) * a.pos(1) < b.pos(0) + size(0) * b.pos(1);
		});

#if 0 //can't erase reverse iterators?!
		std::vector<Entry>::reverse_iterator lasti, i;
		for (i = entries.rbegin(); i != entries.rend(); lasti = i, ++i) {
			if (lasti->pos == i->pos) {
				i->amount += lasti->amount;
				entries.erase(lasti);
			}
		}
#else
		for (int i = entries.size()-1; i >= 0; --i) {
			if (entries[i].pos == entries[i+1].pos) {
				entries[i].amount += entries[i+1].amount;
				entries.erase(entries.begin() + i+1);
			}
		}
#endif
	}
	auto endTime = Clock::now();
	std::chrono::duration<double, std::milli> milliseconds = endTime - startTime;
	std::cout << (milliseconds.count() / 1000.) << " seconds" << std::endl;
	std::cout << iteration << " iterations" << std::endl;
	std::cout << maxNbhdSize << " max nbhd size" << std::endl;

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
#endif

int main(int argc, char** argv) {	

	int modulo = 4;
	int initialstack = 1<<10;
	vec2i size = {1001, 1001};
	
	if (argc > 1) {
		initialstack = atoi(argv[1]);
	}
	if (argc > 2) {
		size.x = size.y = atoi(argv[2]);
	}

	test1(modulo, initialstack, size);
}
