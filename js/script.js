// Add interactivity here if needed
console.log("Z&D Airsoft loaded successfully!");

let currentIndex = 0;
let slides = document.querySelectorAll('.carousel-slide');
let playing = true;
let interval = setInterval(nextSlide, 3000);

function showSlide(index) {
  slides.forEach((slide, i) => {
    slide.style.display = i === index ? 'block' : 'none';
  });
}

function nextSlide() {
  currentIndex = (currentIndex + 1) % slides.length;
  showSlide(currentIndex);
}

function prevSlide() {
  currentIndex = (currentIndex - 1 + slides.length) % slides.length;
  showSlide(currentIndex);
}

function togglePlay() {
  const btn = document.getElementById('playPauseBtn');
  if (playing) {
    clearInterval(interval);
    btn.textContent = '▶️';
  } else {
    interval = setInterval(nextSlide, 3000);
    btn.textContent = '⏸️';
  }
  playing = !playing;
}

showSlide(currentIndex);
